// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @dev Shim base class bắt chước vài hàm cần dùng của VRF wrapper base,
///      để chạy LOCAL không phụ thuộc Chainlink.
abstract contract VRFShim {
    uint256 internal _mockRequestId;
    uint256 internal _mockFeeWei;

    event RandomnessRequested(
        uint256 indexed requestId,
        address indexed requester,
        uint256 paid
    );
    event ShimFeeUpdated(uint256 feeWei);

    constructor() {}

    function setShimFeeWei(uint256 fee) external {
        _mockFeeWei = fee;
        emit ShimFeeUpdated(fee);
    }

    function getRequestPrice() public view returns (uint256) {
        return _mockFeeWei; // mặc định 0 khi local
    }

    /// @notice Bắt chước API request của wrapper: trả (requestId, paid)
    function requestRandomnessPayInNative(
        uint32 /*callbackGasLimit*/,
        uint16 /*requestConfirmations*/,
        uint32 /*numWords*/,
        bytes memory /*extraArgs*/
    ) internal returns (uint256 requestId, uint256 paid) {
        require(msg.value >= _mockFeeWei, "FEE_LOW");
        // sinh requestId giả
        _mockRequestId = uint256(
            keccak256(abi.encode(block.number, msg.sender, block.timestamp))
        );
        emit RandomnessRequested(_mockRequestId, msg.sender, _mockFeeWei);
        return (_mockRequestId, _mockFeeWei);
    }

    /// @dev Subclass phải hiện thực hàm fulfill này (giống Chainlink)
    function fulfillRandomWords(
        uint256 requestId,
        uint256[] memory randomWords
    ) internal virtual;

    /// @notice Hàm trợ giúp để test: tự fulfill từ ngoài (local)
    function _shimFulfill(
        uint256 requestId,
        uint256[] calldata words
    ) external {
        fulfillRandomWords(requestId, words);
    }
}
