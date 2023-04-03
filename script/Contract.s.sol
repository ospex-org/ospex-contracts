// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.4;

import "forge-std/Script.sol";

import "../test/mocks/MockERC20.sol";

import "../src/ContestOracleResolved.sol";

import "../src/SpeculationSpread.sol";

import {SpeculationTotal} from "../src/SpeculationTotal.sol";

import {SpeculationMoneyline} from "../src/SpeculationMoneyline.sol";

import {CFPv1} from "../src/CFPv1.sol";

contract ContractScript is Script {
    function setUp() public {}

    function run() public {
        vm.startBroadcast();
        vm.stopBroadcast();
    }
}
