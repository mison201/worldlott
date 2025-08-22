// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {VRFV2PlusWrapperConsumerBase} from "@chainlink/contracts/src/v0.8/vrf/dev/VRFV2PlusWrapperConsumerBase.sol";
import {VRFV2PlusClient} from "@chainlink/contracts/src/v0.8/vrf/dev/libraries/VRFV2PlusClient.sol";

/// @dev Minimal ReentrancyGuard
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
 * @title VietlotCommitReveal
 * @notice Lottery kiểu 6/N với commit–reveal chống front-running, quay số bằng Chainlink VRF V2+ Wrapper.
 *         Hạch toán: tách prizePoolLocked & operatorFeeAccrued; rút fee chỉ sau finalizeRound().
 *
 * Commit: keccak256(abi.encode(roundId, sortedNumbers[], salt, msg.sender))
 */
contract VietlotCommitRevealV2 is
    VRFV2PlusWrapperConsumerBase,
    ReentrancyGuard
{
    // ===== Game config =====
    uint8 public immutable k; // số lượng con số trên vé (vd 6)
    uint8 public n; // miền số tối đa (vd 55)
    uint256 public ticketPrice; // giá vé (wei)
    address public owner;
    uint16 public feeBps; // phí vận hành theo bps (0..10000)
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
        uint64 revealEnd;
        bool drawRequested;
        bool drawn;
        uint256 requestId;
        uint8[] winningNumbers;
        // Doanh thu (tích luỹ khi commitBuy / commitBuyBatch)
        uint256 salesAmount;
        // ===== Hạch toán tách bạch (khóa sau khi draw) =====
        uint256 operatorFeeAccrued; // phí vận hành tính sau draw
        uint256 prizePoolLocked; // tổng pool thưởng cố định sau draw (trước khi chia theo bậc)
        bool feeWithdrawn; // đã rút phí vận hành chưa
        bool finalized; // đã "chốt vòng" cho phép rút phí
        // Commit–reveal
        mapping(bytes32 => uint256) userCommitQty; // commitHash => qty committed
        mapping(bytes32 => uint256) userRevealQty; // commitHash => qty revealed
        mapping(bytes32 => uint256) revealedCountByCombo; // numbersHash => tổng qty đã reveal
        mapping(bytes32 => uint256) claimedCountByCombo; // numbersHash => tổng qty đã claim (mọi user)
        // (Các biến winners* cũ giữ lại nếu cần theo dõi, nhưng KHÔNG dùng để chi trả)
        uint256 winnersK;
        uint256 winnersK_1;
        uint256 winnersK_2;
        // --- Phân phối an toàn theo cơ chế "pool còn lại / winners còn lại" ---
        uint256 tierPoolRemainingK;
        uint256 tierPoolRemainingK_1;
        uint256 tierPoolRemainingK_2;
        uint256 winnersRemainingK;
        uint256 winnersRemainingK_1;
        uint256 winnersRemainingK_2;
        mapping(bytes32 => bool) comboCounted; // numbersHash => đã cộng totalRevealed vào winnersRemaining chưa
        // --- Ràng buộc claim theo commit của CHÍNH user ---
        mapping(bytes32 => uint256) userClaimedByCommit; // commitHash => qty đã claim bởi chủ commit
    }

    mapping(uint256 => Round) private _rounds;
    uint256 public currentRoundId;

    // ===== VRF params =====
    uint32 public constant CALLBACK_GAS_LIMIT = 2_000_000;
    uint16 public constant REQUEST_CONFIRMATIONS = 3;
    uint32 public constant NUM_WORDS = 2;

    // ===== Events =====
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
    event BatchCommitted(
        uint256 indexed roundId,
        address indexed user,
        bytes32[] commitHashes,
        uint256[] quantities,
        uint256 totalPaid
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
    event Finalized(uint256 indexed id);
    event OperatorFeeWithdrawn(uint256 indexed id, address to, uint256 amount);

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

    /// @notice Chốt vòng: cho phép rút phí vận hành (sau khi draw).
    function finalizeRound(uint256 roundId) external onlyOwner {
        Round storage R = _rounds[roundId];
        require(R.drawn, "NOT_DRAWN");
        require(!R.finalized, "ALREADY_FINAL");
        R.finalized = true;
        emit Finalized(roundId);
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

    /**
     * @notice Commit mua nhiều vé cùng lúc để tiết kiệm gas (batch)
     * @param commitHashes mảng các commitHash (mỗi bộ số nên có salt riêng)
     * @param quantities   mảng số lượng vé tương ứng
     */
    function commitBuyBatch(
        bytes32[] calldata commitHashes,
        uint256[] calldata quantities
    ) external payable nonReentrant {
        uint256 len = commitHashes.length;
        require(len > 0, "EMPTY_BATCH");
        require(len == quantities.length, "LENGTH_MISMATCH");
        require(len <= 20, "BATCH_TOO_LARGE");

        Round storage R = _rounds[currentRoundId];
        require(
            block.timestamp >= R.salesStart && block.timestamp < R.salesEnd,
            "SALES_CLOSED"
        );

        uint256 price = ticketPrice;
        uint256 totalCost = 0;
        uint256 totalQty = 0;

        // Pass 1: validate & sum để tránh ghi state khi thất bại
        for (uint256 i = 0; i < len; i++) {
            uint256 qty = quantities[i];
            require(qty > 0 && qty <= 50, "BAD_QTY");
            totalQty += qty;
            totalCost += price * qty;
        }
        require(totalQty <= 100, "TOTAL_QTY_EXCEEDED");
        require(msg.value == totalCost, "BAD_PAYMENT");

        // Pass 2: mutate & emit
        for (uint256 i = 0; i < len; i++) {
            uint256 qty = quantities[i];
            bytes32 h = commitHashes[i];
            R.userCommitQty[h] += qty;
            emit Committed(R.id, msg.sender, h, qty, price * qty);
        }
        R.salesAmount += totalCost;

        // Event gộp cho toàn batch
        emit BatchCommitted(
            R.id,
            msg.sender,
            commitHashes,
            quantities,
            totalCost
        );
    }

    // ===== Reveal API (Reveal window) =====
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

        bytes32 numbersHash = _validateAndHashNumbers(numbers); // keccak(sorted numbers)
        // reconstruct commitHash
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

        // ===== Chốt hạch toán doanh thu sau draw =====
        uint256 opFee = (R.salesAmount * feeBps) / 10000;
        R.operatorFeeAccrued = opFee;
        R.prizePoolLocked = R.salesAmount - opFee;

        // Khởi tạo pool còn lại theo từng bậc để chi trả an toàn
        R.tierPoolRemainingK = (R.prizePoolLocked * prizeBpsK) / 10000;
        R.tierPoolRemainingK_1 = (R.prizePoolLocked * prizeBpsK_1) / 10000;
        R.tierPoolRemainingK_2 = (R.prizePoolLocked * prizeBpsK_2) / 10000;

        emit Drawn(R.id, win);
    }

    // ===== Claim =====
    /**
     * @notice Claim thưởng CHỈ bởi chủ commit. Bắt buộc kèm salt để tái tạo commitHash của msg.sender.
     *         Chia thưởng theo cơ chế "poolRemaining / winnersRemaining" đảm bảo không vượt pool.
     */
    function claim(
        uint256 roundId,
        uint8[] calldata numbers,
        bytes32 salt,
        uint256 qty
    ) external nonReentrant {
        Round storage R = _rounds[roundId];
        require(R.drawn, "NOT_DRAWN");
        require(qty > 0, "BAD_QTY");

        // Validate & hash combo (trên bản đã sort)
        bytes32 numbersHash = _validateAndHashNumbers(numbers);

        // Ràng buộc claim đúng commit của CHÍNH user
        bytes32 commitHash = keccak256(
            abi.encode(roundId, _sortCopy(numbers), salt, msg.sender)
        );
        uint256 revealedByThis = R.userRevealQty[commitHash];
        require(revealedByThis > 0, "NOT_YOUR_REVEAL");
        require(
            R.userClaimedByCommit[commitHash] + qty <= revealedByThis,
            "OVER_CLAIM_COMMIT"
        );

        // Tổng revealed của combo này (mọi user) & sanity claim theo combo
        uint256 totalRevealed = R.revealedCountByCombo[numbersHash];
        require(totalRevealed > 0, "NOT_REVEALED");
        uint256 claimedCombo = R.claimedCountByCombo[numbersHash];
        require(claimedCombo + qty <= totalRevealed, "OVER_CLAIM");

        // Đếm bậc trúng TRÊN BẢN SORTED
        uint8[] memory sortedNums = _sortCopy(numbers);
        uint8 matches = _countMatchesSorted(sortedNums, R.winningNumbers);
        uint16 prizeShareBps = (matches == k)
            ? prizeBpsK
            : (matches == k - 1)
                ? prizeBpsK_1
                : (matches == k - 2)
                    ? prizeBpsK_2
                    : 0;
        require(prizeShareBps > 0, "NO_PRIZE");

        // Lần đầu combo này claim → cộng totalRevealed vào winnersRemaining của bậc tương ứng
        if (!R.comboCounted[numbersHash]) {
            R.comboCounted[numbersHash] = true;
            if (matches == k) {
                R.winnersRemainingK += totalRevealed;
            } else if (matches == k - 1) {
                R.winnersRemainingK_1 += totalRevealed;
            } else {
                R.winnersRemainingK_2 += totalRevealed;
            }
        }

        // Lấy poolRemaining & winnersRemaining theo bậc
        uint256 poolRemaining;
        uint256 winnersRemaining;
        if (matches == k) {
            poolRemaining = R.tierPoolRemainingK;
            winnersRemaining = R.winnersRemainingK;
        } else if (matches == k - 1) {
            poolRemaining = R.tierPoolRemainingK_1;
            winnersRemaining = R.winnersRemainingK_1;
        } else {
            poolRemaining = R.tierPoolRemainingK_2;
            winnersRemaining = R.winnersRemainingK_2;
        }
        require(winnersRemaining > 0, "NO_WINNERS");

        // Tính payout an toàn (integer division)
        uint256 amountPerTicket = poolRemaining / winnersRemaining;
        uint256 payout = amountPerTicket * qty;
        require(payout > 0, "ZERO_PAYOUT");

        // Ghi nhận claim
        R.claimedCountByCombo[numbersHash] = claimedCombo + qty;
        R.userClaimedByCommit[commitHash] += qty;

        // Trả tiền
        (bool ok, ) = msg.sender.call{value: payout}("");
        require(ok, "TRANSFER_FAIL");

        emit Claimed(roundId, msg.sender, numbersHash, matches, qty, payout);

        // Cập nhật poolRemaining & winnersRemaining sau chi trả
        unchecked {
            poolRemaining -= payout;
            winnersRemaining -= qty;
        }
        if (matches == k) {
            R.tierPoolRemainingK = poolRemaining;
            R.winnersRemainingK = winnersRemaining;
        } else if (matches == k - 1) {
            R.tierPoolRemainingK_1 = poolRemaining;
            R.winnersRemainingK_1 = winnersRemaining;
        } else {
            R.tierPoolRemainingK_2 = poolRemaining;
            R.winnersRemainingK_2 = winnersRemaining;
        }
    }

    // ===== Operator fee withdraw (sau khi finalize) =====
    function withdrawOperatorFee(
        uint256 roundId,
        address to
    ) external onlyOwner nonReentrant {
        Round storage R = _rounds[roundId];
        require(R.drawn, "NOT_DRAWN");
        require(R.finalized, "NOT_FINALIZED");
        require(!R.feeWithdrawn, "FEE_PAID");

        uint256 fee = R.operatorFeeAccrued;
        R.feeWithdrawn = true;

        (bool ok, ) = to.call{value: fee}("");
        require(ok, "FEE_TRANSFER_FAIL");

        emit OperatorFeeWithdrawn(roundId, to, fee);
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

    function getSalesAmount(uint256 roundId) external view returns (uint256) {
        return _rounds[roundId].salesAmount;
    }

    /// @return pool prizePoolLocked; drawn round đã quay số chưa
    function getPrizePool(
        uint256 roundId
    ) external view returns (uint256 pool, bool drawn) {
        Round storage R = _rounds[roundId];
        return (R.prizePoolLocked, R.drawn);
    }

    /// @return fee operatorFeeAccrued; drawable đã đủ điều kiện rút; paid đã rút chưa
    function getOperatorFee(
        uint256 roundId
    ) external view returns (uint256 fee, bool drawable, bool paid) {
        Round storage R = _rounds[roundId];
        fee = R.operatorFeeAccrued;
        drawable = (R.drawn && R.finalized && !R.feeWithdrawn);
        paid = R.feeWithdrawn;
    }

    /// @notice Tổng quan 1 vòng để UI tiện hiển thị
    function getRoundInfo(
        uint256 roundId
    )
        external
        view
        returns (
            uint64 salesStart,
            uint64 salesEnd,
            uint64 revealEnd,
            bool drawRequested,
            bool drawn,
            bool finalized,
            uint256 salesAmount,
            uint256 prizePoolLocked,
            uint256 operatorFeeAccrued,
            bool feeWithdrawn,
            uint8[] memory winningNumbers
        )
    {
        Round storage R = _rounds[roundId];
        salesStart = R.salesStart;
        salesEnd = R.salesEnd;
        revealEnd = R.revealEnd;
        drawRequested = R.drawRequested;
        drawn = R.drawn;
        finalized = R.finalized;
        salesAmount = R.salesAmount;
        prizePoolLocked = R.prizePoolLocked;
        operatorFeeAccrued = R.operatorFeeAccrued;
        feeWithdrawn = R.feeWithdrawn;
        winningNumbers = R.winningNumbers;
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
        return keccak256(abi.encode(tmp)); // numbersHash
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

    // Đếm số trùng trên BẢN ĐÃ SORT
    function _countMatchesSorted(
        uint8[] memory numbersSorted,
        uint8[] storage win
    ) internal view returns (uint8 cnt) {
        uint8[] memory w = win; // copy storage -> memory
        uint256 i = 0;
        uint256 j = 0;
        while (i < numbersSorted.length && j < w.length) {
            if (numbersSorted[i] == w[j]) {
                cnt++;
                i++;
                j++;
            } else if (numbersSorted[i] < w[j]) {
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

    receive() external payable {}
}
