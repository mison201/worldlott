// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {VRFV2PlusWrapperConsumerBase} from "@chainlink/contracts/src/v0.8/vrf/dev/VRFV2PlusWrapperConsumerBase.sol";
import {VRFV2PlusClient} from "@chainlink/contracts/src/v0.8/vrf/dev/libraries/VRFV2PlusClient.sol";

// Simple ReentrancyGuard
abstract contract ReentrancyGuard {
    uint256 private _status = 1;
    modifier nonReentrant() {
        require(_status == 1, "REENTRANCY");
        _status = 2;
        _;
        _status = 1;
    }
}

/**
 * VietlotCommitReveal
 * - Game kiểu 6/N (mặc định 6/55) với commit–reveal để chống front-running.
 * - Commit hash = keccak256(abi.encode(roundId, sortedNumbers[], salt, msg.sender))
 *   => ràng buộc vé với người chơi + vòng chơi; phải reveal trước khi draw.
 */
contract VietlotCommitReveal is VRFV2PlusWrapperConsumerBase, ReentrancyGuard {
    // ===== Game config =====
    uint8 public immutable k; // số lượng con số trên vé (vd 6)
    uint8 public n; // miền số tối đa (vd 55)
    uint256 public ticketPrice; // giá vé (wei của native token)
    address public owner;
    uint16 public feeBps; // phí vận hành theo bps
    uint16 public prizeBpsK; // chia thưởng trúng đủ k
    uint16 public prizeBpsK_1; // chia thưởng trúng k-1
    uint16 public prizeBpsK_2; // chia thưởng trúng k-2

    modifier onlyOwner() {
        require(msg.sender == owner, "ONLY_OWNER");
        _;
    }

    // ===== Round state =====
    struct Round {
        uint256 id;
        uint64 salesStart;
        uint64 salesEnd;
        uint64 revealEnd; // kết thúc reveal (must be < draw time)
        bool drawRequested;
        bool drawn;
        uint256 requestId;
        uint8[] winningNumbers; // sorted length == k
        uint256 salesAmount; // tổng tiền bán vé
        // ==== Commit–reveal data ====
        // Commit của từng user => tổng số vé đã mua theo commit này (chỉ để kiểm soát tiền/limit)
        mapping(bytes32 => uint256) userCommitQty;
        // Số vé đã reveal cho một commit (để không cho reveal > commitQty)
        mapping(bytes32 => uint256) userRevealQty;
        // Tổng vé đã reveal theo combination (định danh bởi numbersHash = keccak(sortedNumbers))
        mapping(bytes32 => uint256) revealedCountByCombo;
        // Claim theo combination cho tất cả người chơi (đã reveal)
        mapping(bytes32 => uint256) claimedCountByCombo;
        // Đếm winner động khi claim (để chia pro-rata)
        uint256 winnersK;
        uint256 winnersK_1;
        uint256 winnersK_2;
    }
    mapping(uint256 => Round) private _rounds;
    uint256 public currentRoundId;

    // ===== VRF params =====
    uint32 public constant CALLBACK_GAS_LIMIT = 2_000_000;
    uint16 public constant REQUEST_CONFIRMATIONS = 3;
    uint32 public constant NUM_WORDS = 2;

    event RoundOpened(
        uint256 indexed id,
        uint64 salesStart,
        uint64 salesEnd,
        uint64 revealEnd
    );
    event Committed(
        uint256 indexed id,
        address indexed user,
        bytes32 commitHash,
        uint256 qty,
        uint256 paid
    );
    event Revealed(
        uint256 indexed id,
        address indexed user,
        bytes32 numbersHash,
        uint256 qty
    );
    event DrawRequested(uint256 indexed id, uint256 requestId, uint256 paidFee);
    event Drawn(uint256 indexed id, uint8[] winningNumbers);
    event Claimed(
        uint256 indexed id,
        address indexed user,
        bytes32 numbersHash,
        uint8 matches,
        uint256 qty,
        uint256 amount
    );

    constructor(
        address vrfWrapper,
        uint8 _k,
        uint8 _n,
        uint256 _ticketPrice,
        uint16 _feeBps,
        uint16 _prizeBpsK,
        uint16 _prizeBpsK_1,
        uint16 _prizeBpsK_2
    ) VRFV2PlusWrapperConsumerBase(vrfWrapper) {
        require(_k >= 3 && _k <= 10, "BAD_K");
        require(_n > _k && _n <= 64, "BAD_N");
        require(
            _feeBps + _prizeBpsK + _prizeBpsK_1 + _prizeBpsK_2 <= 10000,
            "BPS_SUM"
        );
        owner = msg.sender;
        k = _k;
        n = _n;
        ticketPrice = _ticketPrice;
        feeBps = _feeBps;
        prizeBpsK = _prizeBpsK;
        prizeBpsK_1 = _prizeBpsK_1;
        prizeBpsK_2 = _prizeBpsK_2;
    }

    // ===== Admin =====
    function openRound(
        uint64 salesStart,
        uint64 salesEnd,
        uint64 revealEnd
    ) external onlyOwner {
        require(salesStart < salesEnd && salesEnd < revealEnd, "BAD_TIMES");
        require(
            currentRoundId == 0 || _rounds[currentRoundId].drawn == true,
            "PREV_NOT_DRAWN"
        );
        currentRoundId += 1;
        Round storage R = _rounds[currentRoundId];
        R.id = currentRoundId;
        R.salesStart = salesStart;
        R.salesEnd = salesEnd;
        R.revealEnd = revealEnd;
        emit RoundOpened(currentRoundId, salesStart, salesEnd, revealEnd);
    }

    function setParams(
        uint8 _n,
        uint256 _ticketPrice,
        uint16 _feeBps,
        uint16 _pK,
        uint16 _pK1,
        uint16 _pK2
    ) external onlyOwner {
        require(_n > k && _n <= 64, "BAD_N");
        require(_feeBps + _pK + _pK1 + _pK2 <= 10000, "BPS_SUM");
        n = _n;
        ticketPrice = _ticketPrice;
        feeBps = _feeBps;
        prizeBpsK = _pK;
        prizeBpsK_1 = _pK1;
        prizeBpsK_2 = _pK2;
    }

    // ===== Commit API (Sales window) =====
    /**
     * @param commitHash keccak256(abi.encode(roundId, sortedNumbers[0..k-1], salt, msg.sender))
     * @param qty số vé (>=1)
     */
    function commitBuy(
        bytes32 commitHash,
        uint256 qty
    ) external payable nonReentrant {
        Round storage R = _rounds[currentRoundId];
        require(
            block.timestamp >= R.salesStart && block.timestamp < R.salesEnd,
            "SALES_CLOSED"
        );
        require(qty > 0 && qty <= 50, "BAD_QTY");
        uint256 cost = ticketPrice * qty;
        require(msg.value == cost, "BAD_PAYMENT");
        R.userCommitQty[commitHash] += qty;
        R.salesAmount += cost;
        emit Committed(R.id, msg.sender, commitHash, qty, cost);
    }

    // ===== Reveal API (Reveal window) =====
    /**
     * @dev Phải gọi trước khi revealEnd. Hệ thống kiểm tra:
     *  - numbers hợp lệ + sorted, không trùng
     *  - commitHash khớp: keccak(roundId, numbersSorted, salt, msg.sender)
     *  - revealQty + qty <= commitQty
     */
    function reveal(
        uint256 roundId,
        uint8[] calldata numbers,
        bytes32 salt,
        uint256 qty
    ) external nonReentrant {
        Round storage R = _rounds[roundId];
        require(
            block.timestamp >= R.salesEnd && block.timestamp < R.revealEnd,
            "REVEAL_CLOSED"
        );
        require(qty > 0, "BAD_QTY");

        bytes32 numbersHash = _validateAndHashNumbers(numbers); // keccak(sortedNumbers)
        bytes32 commitHash = keccak256(
            abi.encode(roundId, _sortCopy(numbers), salt, msg.sender)
        );
        uint256 committed = R.userCommitQty[commitHash];
        require(committed > 0, "NO_COMMIT");
        require(R.userRevealQty[commitHash] + qty <= committed, "OVER_REVEAL");

        R.userRevealQty[commitHash] += qty;
        R.revealedCountByCombo[numbersHash] += qty;

        emit Revealed(roundId, msg.sender, numbersHash, qty);
    }

    // ===== Draw (sau khi hết reveal) =====
    function requestDraw() external payable onlyOwner nonReentrant {
        Round storage R = _rounds[currentRoundId];
        require(block.timestamp >= R.revealEnd, "REVEAL_NOT_ENDED");
        require(!R.drawRequested, "ALREADY_REQ");

        uint256 price = getRequestPrice();
        require(msg.value >= price, "FEE_LOW");

        VRFV2PlusClient.ExtraArgsV1 memory extra = VRFV2PlusClient.ExtraArgsV1({
            nativePayment: true
        });
        bytes memory args = VRFV2PlusClient._argsToBytes(extra);

        (uint256 requestId, uint256 paid) = requestRandomnessPayInNative(
            CALLBACK_GAS_LIMIT,
            REQUEST_CONFIRMATIONS,
            NUM_WORDS,
            args
        );
        R.drawRequested = true;
        R.requestId = requestId;
        emit DrawRequested(R.id, requestId, paid);

        if (msg.value > paid) {
            (bool ok, ) = msg.sender.call{value: msg.value - paid}("");
            require(ok, "REFUND_FAIL");
        }
    }

    function fulfillRandomWords(
        uint256 requestId,
        uint256[] memory randomWords
    ) internal override {
        Round storage R = _rounds[currentRoundId];
        require(
            R.drawRequested && !R.drawn && requestId == R.requestId,
            "BAD_REQ"
        );
        require(randomWords.length >= 2, "NO_WORDS");

        uint8[] memory win = _drawUniqueNumbers(randomWords, k, n);
        R.winningNumbers = win;
        R.drawn = true;

        emit Drawn(R.id, win);
    }

    // ===== Claim =====
    /**
     * @param numbers vé đã reveal (phải đúng combination)
     * @param qty số vé muốn claim (≤ số vé đã reveal, chưa claim)
     */
    function claim(
        uint256 roundId,
        uint8[] calldata numbers,
        uint256 qty
    ) external nonReentrant {
        Round storage R = _rounds[roundId];
        require(R.drawn, "NOT_DRAWN");
        require(qty > 0, "BAD_QTY");

        bytes32 numbersHash = _validateAndHashNumbers(numbers);
        uint256 totalRevealed = R.revealedCountByCombo[numbersHash];
        require(totalRevealed > 0, "NOT_REVEALED");

        // còn lại chưa claim
        uint256 claimed = R.claimedCountByCombo[numbersHash];
        require(claimed + qty <= totalRevealed, "OVER_CLAIM");

        // tính bậc trúng
        uint8 matches = _countMatches(numbers, R.winningNumbers);
        uint16 prizeShareBps = (matches == k)
            ? prizeBpsK
            : (matches == k - 1)
                ? prizeBpsK_1
                : (matches == k - 2)
                    ? prizeBpsK_2
                    : 0;
        require(prizeShareBps > 0, "NO_PRIZE");

        uint256 operatorFee = (R.salesAmount * feeBps) / 10000;
        uint256 prizePool = R.salesAmount - operatorFee;

        // tăng bộ đếm winners theo tier (động)
        if (matches == k) R.winnersK += qty;
        else if (matches == k - 1) R.winnersK_1 += qty;
        else if (matches == k - 2) R.winnersK_2 += qty;

        uint256 winners = (matches == k)
            ? R.winnersK
            : (matches == k - 1)
                ? R.winnersK_1
                : R.winnersK_2;
        uint256 tierPool = (prizePool * prizeShareBps) / 10000;
        uint256 amountPerTicket = tierPool / winners;
        uint256 payout = amountPerTicket * qty;

        R.claimedCountByCombo[numbersHash] = claimed + qty;

        (bool ok, ) = msg.sender.call{value: payout}("");
        require(ok, "TRANSFER_FAIL");

        emit Claimed(roundId, msg.sender, numbersHash, matches, qty, payout);
    }

    // ===== Views =====
    function getWinningNumbers(
        uint256 roundId
    ) external view returns (uint8[] memory) {
        require(_rounds[roundId].drawn, "NOT_DRAWN");
        return _rounds[roundId].winningNumbers;
    }
    function getRequestPrice() public view returns (uint256) {
        return
            i_vrfV2PlusWrapper.calculateRequestPriceNative(
                CALLBACK_GAS_LIMIT,
                NUM_WORDS
            );
    }

    // ===== Internal helpers =====
    function _validateAndHashNumbers(
        uint8[] calldata numbers
    ) internal view returns (bytes32) {
        require(numbers.length == k, "BAD_LEN");
        uint8[] memory tmp = _sortCopy(numbers);
        for (uint256 i = 0; i < k; i++) {
            require(tmp[i] >= 1 && tmp[i] <= n, "OUT_RANGE");
            if (i > 0) require(tmp[i] != tmp[i - 1], "DUP");
        }
        return keccak256(abi.encode(tmp)); // numbersHash (không gắn user)
    }

    function _sortCopy(
        uint8[] calldata arr
    ) internal pure returns (uint8[] memory out) {
        out = new uint8[](arr.length);
        for (uint256 i = 0; i < arr.length; i++) {
            out[i] = arr[i];
        }
        // insertion sort (k nhỏ)
        for (uint256 i = 1; i < out.length; i++) {
            uint8 key = out[i];
            uint256 j = i;
            while (j > 0 && out[j - 1] > key) {
                out[j] = out[j - 1];
                j--;
            }
            out[j] = key;
        }
    }

    function _countMatches(
        uint8[] calldata numbers,
        uint8[] storage win
    ) internal view returns (uint8 cnt) {
        uint8[] memory w = win;
        uint256 i = 0;
        uint256 j = 0;
        while (i < numbers.length && j < w.length) {
            if (numbers[i] == w[j]) {
                cnt++;
                i++;
                j++;
            } else if (numbers[i] < w[j]) {
                i++;
            } else {
                j++;
            }
        }
    }

    function _drawUniqueNumbers(
        uint256[] memory words,
        uint8 _k,
        uint8 _n
    ) internal pure returns (uint8[] memory out) {
        out = new uint8[](_k);
        uint8[] memory bag = new uint8[](_n);
        for (uint8 i = 0; i < _n; i++) {
            bag[i] = i + 1;
        }
        uint256 r0 = words[0];
        uint256 r1 = words.length > 1 ? words[1] : 1;
        for (uint8 i = 0; i < _k; i++) {
            uint256 seed = uint256(keccak256(abi.encode(r0, r1, i)));
            uint256 idx = seed % (_n - i);
            out[i] = bag[idx];
            bag[idx] = bag[_n - 1 - i];
        }
        // sort ascending
        for (uint8 a = 0; a < _k; a++) {
            for (uint8 b = a + 1; b < _k; b++) {
                if (out[b] < out[a]) {
                    (out[a], out[b]) = (out[b], out[a]);
                }
            }
        }
    }

    // (Tùy chọn) rút phí vận hành sau khi đã draw — demo đơn giản
    function withdrawOperatorFee(
        uint256 roundId,
        address to
    ) external onlyOwner nonReentrant {
        Round storage R = _rounds[roundId];
        require(R.drawn, "NOT_DRAWN");
        uint256 fee = (R.salesAmount * feeBps) / 10000;
        uint256 pool = R.salesAmount; // giữ để tránh double-withdraw (có thể tinh chỉnh)
        R.salesAmount = 0;
        (bool ok, ) = to.call{value: fee}("");
        require(ok, "FEE_TRANSFER_FAIL");
        // Lưu ý: để production nên hạch toán pool thưởng riêng thay vì zeroing salesAmount.
    }

    receive() external payable {}
}
