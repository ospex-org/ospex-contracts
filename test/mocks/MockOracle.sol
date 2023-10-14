// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

contract MockOracle {

    // mapping(address => uint96) /* oracle node */ /* LINK balance */ private s_withdrawableTokens;

    function sendRequest (
        uint64 subscriptionId,
        bytes calldata data,
        uint16 dataVersion,
        uint32 callbackGasLimit,
        bytes32 donId
    )  external /* override */ returns (bytes32) {
        return bytes32(uint256(callbackGasLimit));
    }

    // function getRegistry() external view returns (address) {
    //     return (address(0x5));
    // }
}
