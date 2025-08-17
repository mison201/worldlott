// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @notice Interface tối thiểu để gọi fulfill trong consumer
interface ILotteryConsumer {
    function fulfillRandomWords(
        uint256 requestId,
        uint256[] memory randomWords
    ) external;
}

/**
 * @title MockVRFWrapper
 * @notice Giả lập Chainlink VRF V2+ Wrapper cho môi trường local/Hardhat.
 * - Tự do gọi request, sau đó dùng `fulfill(...)` để bắn callback thủ công.
 * - Phí VRF mặc định = 0 khi test; có thể chỉnh bằng `setMockFeeWei`.
 */
contract MockVRFWrapper {
    uint256 public lastRequestId;
    address public lastRequester;
    uint256 public mockFeeWei; // phí ảo nếu bạn muốn test thiếu phí (mặc định 0)

    event RandomnessRequested(
        uint256 indexed requestId,
        address indexed requester
    );
    event MockFeeUpdated(uint256 feeWei);

    constructor() {
        mockFeeWei = 0;
    }

    /// @notice Đặt phí ảo cho request (để test path "FEE_LOW" ở consumer nếu có)
    function setMockFeeWei(uint256 fee) external {
        mockFeeWei = fee;
        emit MockFeeUpdated(fee);
    }

    /// @notice Bắt chước API của Wrapper: tính phí theo gasLimit & numWords.
    ///         Ở local ta trả 0 để tiện test.
    function calculateRequestPriceNative(
        uint32 /*callbackGasLimit*/,
        uint32 /*numWords*/
    ) external view returns (uint256) {
        return mockFeeWei; // mặc định 0; nếu bạn set khác, consumer phải gửi >= số này
    }

    /// @notice Bắt chước API request của Wrapper (trả về requestId & số phí đã thu).
    ///         Không callback ngay; bạn sẽ tự gọi fulfill(...) sau.
    function requestRandomnessPayInNative(
        uint32 /*callbackGasLimit*/,
        uint16 /*requestConfirmations*/,
        uint32 /*numWords*/,
        bytes calldata /*extraArgs*/
    ) external payable returns (uint256 requestId, uint256 paid) {
        // Nếu bạn muốn test thiếu phí, có thể bật mockFeeWei > 0
        require(msg.value >= mockFeeWei, "Insufficient mock fee");
        // requestId giả lập dựa trên block & msg.sender
        lastRequestId = uint256(
            keccak256(abi.encode(block.number, msg.sender, block.timestamp))
        );
        lastRequester = msg.sender;
        emit RandomnessRequested(lastRequestId, msg.sender);
        return (lastRequestId, mockFeeWei);
    }

    /// @notice Hàm trợ giúp để bắn callback fulfill về consumer (lottery).
    /// @param consumer địa chỉ contract consumer (VietlotCommitReveal)
    /// @param requestId id đã trả từ `requestRandomnessPayInNative`
    /// @param words mảng randomWords tuỳ bạn set (ví dụ [123,456])
    function fulfill(
        address consumer,
        uint256 requestId,
        uint256[] calldata words
    ) external {
        ILotteryConsumer(consumer).fulfillRandomWords(requestId, words);
    }

    // Nhận ETH (ví dụ bạn muốn nạp trước để refund… không bắt buộc dùng)
    receive() external payable {}
}
