// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./mocks/VRFShim.sol";

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
 * @title VietlotCommitRevealLocal
 * @notice Bản dành cho LOCAL: logic commit–reveal + tách pool/phí giống hệt bản chuẩn,
 *         nhưng dùng VRFShim thay vì Chainlink base.
 */
contract VietlotCommitRevealLocal is VRFShim, ReentrancyGuard {
    uint8 public immutable k;
    uint8 public n;
    uint256 public ticketPrice;
    address public owner;
    uint16 public feeBps;
    uint16 public prizeBpsK;
    uint16 public prizeBpsK_1;
    uint16 public prizeBpsK_2;

    modifier onlyOwner() {
        require(msg.sender == owner, "ONLY_OWNER");
        _;
    }

    struct Round {
        uint256 id;
        uint64 salesStart;
        uint64 salesEnd;
        uint64 revealEnd;
        bool drawRequested;
        bool drawn;
        uint256 requestId;
        uint8[] winningNumbers;
        uint256 salesAmount;
        uint256 operatorFeeAccrued;
        uint256 prizePoolLocked;
        bool feeWithdrawn;
        bool finalized;
        mapping(bytes32 => uint256) userCommitQty;
        mapping(bytes32 => uint256) userRevealQty;
        mapping(bytes32 => uint256) revealedCountByCombo;
        mapping(bytes32 => uint256) claimedCountByCombo;
        uint256 winnersK;
        uint256 winnersK_1;
        uint256 winnersK_2;
    }

    mapping(uint256 => Round) private _rounds;
    uint256 public currentRoundId;

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
    event Finalized(uint256 indexed id);
    event OperatorFeeWithdrawn(uint256 indexed id, address to, uint256 amount);

    constructor(
        uint8 _k,
        uint8 _n,
        uint256 _ticketPrice,
        uint16 _feeBps,
        uint16 _pK,
        uint16 _pK1,
        uint16 _pK2
    ) {
        require(_k >= 3 && _k <= 10, "BAD_K");
        require(_n > _k && _n <= 64, "BAD_N");
        require(_feeBps + _pK + _pK1 + _pK2 <= 10000, "BPS_SUM");
        owner = msg.sender;
        k = _k;
        n = _n;
        ticketPrice = _ticketPrice;
        feeBps = _feeBps;
        prizeBpsK = _pK;
        prizeBpsK_1 = _pK1;
        prizeBpsK_2 = _pK2;
    }

    // ----- Admin -----
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

    function finalizeRound(uint256 roundId) external onlyOwner {
        Round storage R = _rounds[roundId];
        require(R.drawn, "NOT_DRAWN");
        require(!R.finalized, "ALREADY_FINAL");
        R.finalized = true;
        emit Finalized(roundId);
    }

    // ----- Sales -----
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

    // ----- Reveal -----
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
        bytes32 numbersHash = _validateAndHashNumbers(numbers);
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

    // ----- Draw -----
    function requestDraw() external payable onlyOwner nonReentrant {
        Round storage R = _rounds[currentRoundId];
        require(block.timestamp >= R.revealEnd, "REVEAL_NOT_ENDED");
        require(!R.drawRequested, "ALREADY_REQ");
        uint256 price = getRequestPrice();
        require(msg.value >= price, "FEE_LOW");

        (uint256 requestId, uint256 paid) = requestRandomnessPayInNative(
            2_000_000,
            3,
            2,
            ""
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

        uint256 opFee = (R.salesAmount * feeBps) / 10000;
        R.operatorFeeAccrued = opFee;
        R.prizePoolLocked = R.salesAmount - opFee;

        emit Drawn(R.id, win);
    }

    // ----- Claim -----
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
        uint256 claimed = R.claimedCountByCombo[numbersHash];
        require(claimed + qty <= totalRevealed, "OVER_CLAIM");

        uint8 matches = _countMatches(numbers, R.winningNumbers);
        uint16 share = (matches == k)
            ? prizeBpsK
            : (matches == k - 1)
                ? prizeBpsK_1
                : (matches == k - 2)
                    ? prizeBpsK_2
                    : 0;
        require(share > 0, "NO_PRIZE");

        uint256 prizePool = R.prizePoolLocked;
        if (matches == k) R.winnersK += qty;
        else if (matches == k - 1) R.winnersK_1 += qty;
        else if (matches == k - 2) R.winnersK_2 += qty;

        uint256 winners = (matches == k)
            ? R.winnersK
            : (matches == k - 1)
                ? R.winnersK_1
                : R.winnersK_2;
        uint256 tierPool = (prizePool * share) / 10000;
        uint256 amountPerTicket = (winners > 0) ? (tierPool / winners) : 0;
        uint256 payout = amountPerTicket * qty;
        require(payout > 0, "ZERO_PAYOUT");

        R.claimedCountByCombo[numbersHash] = claimed + qty;
        (bool ok, ) = msg.sender.call{value: payout}("");
        require(ok, "TRANSFER_FAIL");

        emit Claimed(roundId, msg.sender, numbersHash, matches, qty, payout);
    }

    // ----- Fee withdraw (sau finalize) -----
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

    // ----- Views -----
    function getWinningNumbers(
        uint256 roundId
    ) external view returns (uint8[] memory) {
        require(_rounds[roundId].drawn, "NOT_DRAWN");
        return _rounds[roundId].winningNumbers;
    }

    function getSalesAmount(uint256 roundId) external view returns (uint256) {
        return _rounds[roundId].salesAmount;
    }

    function getPrizePool(
        uint256 roundId
    ) external view returns (uint256 pool, bool drawn) {
        Round storage R = _rounds[roundId];
        return (R.prizePoolLocked, R.drawn);
    }

    function getOperatorFee(
        uint256 roundId
    ) external view returns (uint256 fee, bool drawable, bool paid) {
        Round storage R = _rounds[roundId];
        fee = R.operatorFeeAccrued;
        drawable = (R.drawn && R.finalized && !R.feeWithdrawn);
        paid = R.feeWithdrawn;
    }

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

    // ----- Internals -----
    function _validateAndHashNumbers(
        uint8[] calldata numbers
    ) internal view returns (bytes32) {
        require(numbers.length == k, "BAD_LEN");
        uint8[] memory tmp = _sortCopy(numbers);
        for (uint256 i = 0; i < k; i++) {
            require(tmp[i] >= 1 && tmp[i] <= n, "OUT_RANGE");
            if (i > 0) require(tmp[i] != tmp[i - 1], "DUP");
        }
        return keccak256(abi.encode(tmp));
    }

    function _sortCopy(
        uint8[] calldata arr
    ) internal pure returns (uint8[] memory out) {
        out = new uint8[](arr.length);
        for (uint256 i = 0; i < arr.length; i++) {
            out[i] = arr[i];
        }
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
