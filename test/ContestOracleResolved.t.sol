// SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;

import { ContestOracleResolved } from "src/ContestOracleResolved.sol";

contract ContestOracleResolvedHarness is ContestOracleResolved {

    // I don't think this function is used in tests

    // function exposed_executeRequest() external returns (bytes32) {
    //     return executeRequest();
    // }

    constructor(
        address oracle, 
        address linkTokenAddress, 
        address linkBillingRegistryProxyAddress,
        bytes32 createContestSourceHashValue,
        bytes32 scoreContestSourceHashValue
    ) 
        ContestOracleResolved(
            oracle, 
            linkTokenAddress, 
            linkBillingRegistryProxyAddress,
            createContestSourceHashValue,
            scoreContestSourceHashValue
        ) 
    {}

    function exposed_fulfillRequest(bytes32 requestId, bytes memory response) external {
        return fulfillRequest(requestId, response, "");
    }

}