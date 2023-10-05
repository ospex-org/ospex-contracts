// SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;

contract MockOracle {

    // mapping(address => uint96) /* oracle node */ /* LINK balance */ private s_withdrawableTokens;

    function sendRequest (
        uint64 subscriptionId,
        bytes calldata data,
        uint32 gasLimit
    )  external returns (bytes32) {
        return bytes32(uint256(gasLimit));
    }

    function getRegistry() external view returns (address) {
        return (address(0x5));
    }
}
