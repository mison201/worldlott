// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface ILottery {
    function fulfillRandomWords(
        uint256 requestId,
        uint256[] memory randomWords
    ) external;
}

contract MockVRFWrapper {
    uint256 public lastRequestId;
    address public lastRequester;

    event RandomnessRequested(uint256 indexed requestId, address requester);

    function calculateRequestPriceNative(
        uint32 /*gas*/,
        uint32 /*numWords*/
    ) external pure returns (uint256) {
        return 0; // free in local
    }

    function requestRandomnessPayInNative(
        uint32 /*gas*/,
        uint16 /*conf*/,
        uint32 /*numWords*/,
        bytes calldata /*args*/
    ) external payable returns (uint256 requestId, uint256 paid) {
        lastRequestId = uint256(
            keccak256(abi.encode(block.number, msg.sender, block.timestamp))
        );
        lastRequester = msg.sender;
        emit RandomnessRequested(lastRequestId, msg.sender);
        return (lastRequestId, 0);
    }

    // Helper to simulate callback
    function fulfill(
        address consumer,
        uint256 requestId,
        uint256[] calldata words
    ) external {
        ILottery(consumer).fulfillRandomWords(requestId, words);
    }
}
