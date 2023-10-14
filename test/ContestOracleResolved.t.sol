// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import { ContestOracleResolved } from "src/ContestOracleResolved.sol";

contract ContestOracleResolvedHarness is ContestOracleResolved {

    // I don't think this function is used in tests

    // function exposed_executeRequest() external returns (bytes32) {
    //     return executeRequest();
    // }

    constructor(
        address _router, 
        bytes32 _donId,
        address linkTokenAddress, 
        bytes32 createContestSourceHashValue,
        bytes32 scoreContestSourceHashValue
    ) 
        ContestOracleResolved(
            _router, 
            _donId,
            linkTokenAddress, 
            createContestSourceHashValue,
            scoreContestSourceHashValue
        ) 
    {}

    function exposed_fulfillRequest(bytes32 requestId, bytes memory response) external {
        return fulfillRequest(requestId, response, "");
    }

}