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

contract VietlotCommitRevealV3 is
    VRFV2PlusWrapperConsumerBase,
    ReentrancyGuard
{
    // ===== Game config =====
    uint8 public immutable k; // số lượng con số trên vé (vd 6)
    uint8 public n; // miền số tối đa (vd 55, <= 64)
    uint256 public ticketPrice; // giá vé (wei)
    address public owner;
    uint16 public feeBps; // phí vận hành theo bps (0..10000)
    uint16 public prizeBpsK; // chia thưởng trúng đủ k
    uint16 public prizeBpsK_1; // chia thưởng trúng k-1
    uint16 public prizeBpsK_2; // chia thưởng trúng k-2

    bool public paused;

    modifier onlyOwner() {
        require(msg.sender == owner, "ONLY_OWNER");
        _;
    }
    modifier whenNotPaused() {
        require(!paused, "PAUSED");
        _;
    }

    // ===== Round state =====
    struct Round {
        uint256 id;
        uint64 salesStart;
        uint64 salesEnd;
        uint64 revealEnd;
        uint64 claimDeadline; // deadline claim (0 = không dùng)
        bool drawRequested;
        bool drawn;
        uint256 requestId;
        uint64 drawRequestedAt; // timestamp yêu cầu VRF (phòng kẹt)
        uint8[] winningNumbers;
        uint64 winningMask; // bitmask 64-bit của dãy thắng
        // Doanh thu (tích luỹ khi commitBuy / commitBuyBatch)
        uint256 salesAmount;
        // ===== Hạch toán tách bạch (khóa sau khi draw) =====
        uint256 operatorFeeAccrued; // phí vận hành tính sau draw
        uint256 prizePoolLocked; // tổng pool thưởng cố định sau draw
        bool feeWithdrawn; // đã rút phí vận hành chưa
        bool finalized; // đã "chốt vòng" cho phép rút phí
        // Commit–reveal
        mapping(bytes32 => uint256) userCommitQty; // commitHash => qty committed
        mapping(bytes32 => uint256) userRevealQty; // commitHash => qty revealed
        mapping(bytes32 => uint256) revealedCountByCombo; // numbersHash => tổng qty đã reveal
        mapping(bytes32 => uint256) claimedCountByCombo; // numbersHash => tổng qty đã claim (mọi user)
        // --- Ghi danh combos và bitmask để snapshot sau draw ---
        bytes32[] combos; // danh sách numbersHash unique
        mapping(bytes32 => bool) comboSeen; // đã ghi vào combos chưa
        mapping(bytes32 => uint64) comboMask; // numbersHash => bitmask (1..64)
        // --- Snapshot winners ---
        bool snapshotDone;
        uint256 totalWinnersK;
        uint256 totalWinnersK_1;
        uint256 totalWinnersK_2;
        // --- Phân phối an toàn (pool còn lại / winners còn lại) ---
        uint256 tierPoolRemainingK;
        uint256 tierPoolRemainingK_1;
        uint256 tierPoolRemainingK_2;
        uint256 winnersRemainingK;
        uint256 winnersRemainingK_1;
        uint256 winnersRemainingK_2;
        // --- Ràng buộc claim theo commit của CHÍNH user ---
        mapping(bytes32 => uint256) userClaimedByCommit; // commitHash => qty đã claim bởi chủ commit
    }

    mapping(uint256 => Round) private _rounds;
    uint256 public currentRoundId;

    // ===== VRF params =====
    uint32 public constant CALLBACK_GAS_LIMIT = 2_000_000;
    uint16 public constant REQUEST_CONFIRMATIONS = 3;
    uint32 public constant NUM_WORDS = 2;
    uint64 public constant REREQUEST_GRACE = 1 hours; // timeout để re-request VRF

    // ===== Events =====
    event RoundOpened(
        uint256 indexed id,
        uint64 salesStart,
        uint64 salesEnd,
        uint64 revealEnd
    ); // giữ tương thích
    event RoundOpenedExt(
        uint256 indexed id,
        uint64 salesStart,
        uint64 salesEnd,
        uint64 revealEnd,
        uint64 claimDeadline
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
    event DrawReRequested(
        uint256 indexed id,
        uint256 requestId,
        uint256 paidFee
    );
    event Drawn(uint256 indexed id, uint8[] winningNumbers);
    event SnapshotProgress(
        uint256 indexed id,
        uint256 processed,
        uint256 total,
        bool done
    );
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
    event UnclaimedSwept(uint256 indexed id, address to, uint256 amount);
    event Paused(bool status);
    event OwnershipTransferred(
        address indexed previousOwner,
        address indexed newOwner
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
        uint64 revealEnd,
        uint64 claimDeadline
    ) external onlyOwner {
        require(salesStart < salesEnd && salesEnd < revealEnd, "BAD_TIMES");
        require(
            currentRoundId == 0 || _rounds[currentRoundId].drawn == true,
            "PREV_NOT_DRAWN"
        );
        if (claimDeadline != 0) {
            require(claimDeadline > revealEnd, "BAD_CLAIM_DEADLINE");
        }
        currentRoundId += 1;
        Round storage R = _rounds[currentRoundId];
        R.id = currentRoundId;
        R.salesStart = salesStart;
        R.salesEnd = salesEnd;
        R.revealEnd = revealEnd;
        R.claimDeadline = claimDeadline;
        emit RoundOpened(currentRoundId, salesStart, salesEnd, revealEnd);
        emit RoundOpenedExt(
            currentRoundId,
            salesStart,
            salesEnd,
            revealEnd,
            claimDeadline
        );
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
        require(
            currentRoundId == 0 || _rounds[currentRoundId].drawn,
            "ROUND_ACTIVE"
        );
        n = _n;
        ticketPrice = _ticketPrice;
        feeBps = _feeBps;
        prizeBpsK = _pK;
        prizeBpsK_1 = _pK1;
        prizeBpsK_2 = _pK2;
    }

    function pause() external onlyOwner {
        paused = true;
        emit Paused(true);
    }

    function unpause() external onlyOwner {
        paused = false;
        emit Paused(false);
    }

    function transferOwnership(address newOwner) external onlyOwner {
        require(newOwner != address(0), "ZERO_ADDR");
        emit OwnershipTransferred(owner, newOwner);
        owner = newOwner;
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
    function commitBuy(
        bytes32 commitHash,
        uint256 qty
    ) external payable nonReentrant whenNotPaused {
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

    function commitBuyBatch(
        bytes32[] calldata commitHashes,
        uint256[] calldata quantities
    ) external payable nonReentrant whenNotPaused {
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

        for (uint256 i = 0; i < len; i++) {
            uint256 qty = quantities[i];
            require(qty > 0 && qty <= 50, "BAD_QTY");
            totalQty += qty;
            totalCost += price * qty;
        }
        require(totalQty <= 100, "TOTAL_QTY_EXCEEDED");
        require(msg.value == totalCost, "BAD_PAYMENT");

        for (uint256 i = 0; i < len; i++) {
            uint256 qty = quantities[i];
            bytes32 h = commitHashes[i];
            R.userCommitQty[h] += qty;
            emit Committed(R.id, msg.sender, h, qty, price * qty);
        }
        R.salesAmount += totalCost;

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
    ) external nonReentrant whenNotPaused {
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

        // Lần đầu thấy combo này ở round => lưu vào danh sách + bitmask
        if (!R.comboSeen[numbersHash]) {
            R.comboSeen[numbersHash] = true;
            R.combos.push(numbersHash);
            uint8[] memory sorted = _sortCopy(numbers);
            R.comboMask[numbersHash] = _toMask(sorted);
        }

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
        R.drawRequestedAt = uint64(block.timestamp);
        emit DrawRequested(R.id, requestId, paid);

        if (msg.value > paid) {
            (bool ok, ) = msg.sender.call{value: msg.value - paid}("");
            require(ok, "REFUND_FAIL");
        }
    }

    /// @notice Re-request VRF nếu kẹt (không callback sau REREQUEST_GRACE)
    function reRequestDrawIfStuck(
        uint256 roundId
    ) external payable onlyOwner nonReentrant {
        Round storage R = _rounds[roundId];
        require(roundId == currentRoundId, "NOT_CURRENT");
        require(R.drawRequested && !R.drawn, "NOT_STUCK");
        require(
            block.timestamp >= (uint256(R.drawRequestedAt) + REREQUEST_GRACE),
            "EARLY"
        );

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
        R.requestId = requestId;
        R.drawRequestedAt = uint64(block.timestamp);
        emit DrawReRequested(R.id, requestId, paid);

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
        R.winningMask = _toMask(win);
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

    /// @notice Tally tổng winners theo từng bậc (phân trang để tránh out-of-gas)
    function snapshotWinners(
        uint256 roundId,
        uint256 start,
        uint256 limit
    ) external {
        Round storage R = _rounds[roundId];
        require(R.drawn, "NOT_DRAWN");
        require(!R.snapshotDone, "SNAP_DONE");
        uint256 total = R.combos.length;
        uint256 end = start + limit;
        if (end > total) end = total;

        for (uint256 i = start; i < end; i++) {
            bytes32 h = R.combos[i];
            uint256 qty = R.revealedCountByCombo[h];
            if (qty == 0) continue;
            uint64 m = R.comboMask[h];
            uint8 matches = _countMatchesMask(m, R.winningMask);
            if (matches == k) {
                R.totalWinnersK += qty;
            } else if (matches == k - 1) {
                R.totalWinnersK_1 += qty;
            } else if (matches == k - 2) {
                R.totalWinnersK_2 += qty;
            }
        }

        bool done = (end == total);
        if (done) {
            R.winnersRemainingK = R.totalWinnersK;
            R.winnersRemainingK_1 = R.totalWinnersK_1;
            R.winnersRemainingK_2 = R.totalWinnersK_2;
            R.snapshotDone = true;
        }
        emit SnapshotProgress(roundId, end, total, done);
    }

    // ===== Claim =====
    function claim(
        uint256 roundId,
        uint8[] calldata numbers,
        bytes32 salt,
        uint256 qty
    ) external nonReentrant whenNotPaused {
        Round storage R = _rounds[roundId];
        require(R.drawn, "NOT_DRAWN");
        require(R.snapshotDone, "SNAP_REQUIRED");
        if (R.claimDeadline != 0) {
            require(block.timestamp <= R.claimDeadline, "CLAIM_ENDED");
        }
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

        // Đếm bậc trúng (dùng mask cho nhanh)
        uint8[] memory sortedNums = _sortCopy(numbers);
        uint8 matches = _countMatchesMask(_toMask(sortedNums), R.winningMask);
        uint16 prizeShareBps = (matches == k)
            ? prizeBpsK
            : (matches == k - 1)
                ? prizeBpsK_1
                : (matches == k - 2)
                    ? prizeBpsK_2
                    : 0;
        require(prizeShareBps > 0, "NO_PRIZE");

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

    /// @notice Sweep phần thưởng còn dư sau hạn claim (nếu có)
    function sweepUnclaimed(
        uint256 roundId,
        address to
    ) external onlyOwner nonReentrant {
        Round storage R = _rounds[roundId];
        require(R.drawn && R.finalized, "NOT_READY");
        require(
            R.claimDeadline != 0 && block.timestamp > R.claimDeadline,
            "EARLY"
        );

        uint256 leftover = R.tierPoolRemainingK +
            R.tierPoolRemainingK_1 +
            R.tierPoolRemainingK_2;
        require(leftover > 0, "NO_LEFTOVER");

        // zero out pools
        R.tierPoolRemainingK = 0;
        R.tierPoolRemainingK_1 = 0;
        R.tierPoolRemainingK_2 = 0;

        (bool ok, ) = to.call{value: leftover}("");
        require(ok, "SWEEP_FAIL");

        emit UnclaimedSwept(roundId, to, leftover);
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
            uint8[] memory winningNumbers,
            bool snapshotDone,
            uint64 claimDeadline
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
        snapshotDone = R.snapshotDone;
        claimDeadline = R.claimDeadline;
    }

    function getCombosCount(uint256 roundId) external view returns (uint256) {
        return _rounds[roundId].combos.length;
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

    // bitmask từ dãy số đã sort (1..64)
    function _toMask(uint8[] memory arr) internal pure returns (uint64 mask) {
        for (uint256 i = 0; i < arr.length; i++) {
            uint8 v = arr[i];
            require(v >= 1 && v <= 64, "BAD_NUM");
            mask |= (uint64(1) << (v - 1));
        }
    }

    // popcount trên mask giao
    function _countMatchesMask(
        uint64 a,
        uint64 b
    ) internal pure returns (uint8) {
        uint64 x = a & b;
        uint8 c;
        while (x != 0) {
            x &= (x - 1);
            c++;
        }
        return c;
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

    // Chặn gửi ETH trực tiếp (tránh kẹt tiền nhầm gửi)
    fallback() external payable {
        revert("NO_DIRECT_SEND");
    }
    receive() external payable {
        revert("NO_DIRECT_SEND");
    }
}
