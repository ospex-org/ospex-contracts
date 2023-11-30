// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import "forge-std/Test.sol";
import "./mocks/MockERC20.sol";
import "./ContestOracleResolved.t.sol";
import "../src/SpeculationSpread.sol";
import "../src/CFPStructs.sol";
import {SpeculationTotal} from "../src/SpeculationTotal.sol";
import {SpeculationMoneyline} from "../src/SpeculationMoneyline.sol";
import {CFPv1} from "../src/CFPv1.sol";
import "./mocks/MockOracle.sol";
import "./mocks/MockERC677.sol";

contract ContractTest is Test {
    using stdStorage for StdStorage;

    ContestOracleResolvedHarness contestOracleResolved;
    CFPv1 cfp;
    MockERC20 erc20;
    SpeculationSpread speculationSpread;
    SpeculationTotal speculationTotal;
    SpeculationMoneyline speculationMoneyline;
    ERC677 link;
    MockOracle mockOracle;

    address alice = address(0x1);
    address bob = address(0x2);
    address carol = address(0x3);
    address vince = address(0xA8eb19F9B7c2b2611C1279423A0CB2aee3735320);
    address DAOAddress = address(0xB8720b00C8FA95aD1bA62AEd4eEcD5567cf1dFD7);
    uint256 public currentContestCounter = 0;
    // this dummyVal is the equivalent of the value 40070091672358400
    bytes public dummyVal = abi.encodePacked(bytes32(0x000000000000000000000000000000000000000000000000008e5b893c3f8e00));
    bytes32 public RELAYER_ROLE =
        0xe2b7fb3b832174769106daebcfd6d1970523240dda11281102db9363b83b0dc4;
    bytes32 public CONTEST_CONTRACT_ADDRESS =
        0x539b77d7cf412eeb485a45b4b9510d2a2a989f145a34f462acd2b99cc0728158;
    bytes32 public SCORE_MANAGER =
        0x1e16087bdfce8818de5eeb4bfb2468db6c3e3a609902de86451d6bcb221ca1fd;
    bytes32 public SOURCEMANAGER_ROLE = 
        0xa6014ca5c8e8b2d25a296a78ce7b6f1a09ff202791c9e89eb11dd451ba2e1392;

    function setUp() public {
        link = new ERC677(
            address(this),
            100 * 10 ** 18,
            "LinkToken",
            "LINK"
        );

        erc20 = new MockERC20(
            "StandardToken",
            "ST",
            address(this),
            type(uint256).max
        );

        mockOracle = new MockOracle();

        contestOracleResolved = new ContestOracleResolvedHarness(
            address(mockOracle),
            bytes32(0x66756e2d706f6c79676f6e2d6d756d6261692d31000000000000000000000000), // DON ID from: https://functions.chain.link/mumbai
            address(link),
            keccak256(abi.encodePacked("test1")),
            keccak256(abi.encodePacked("test2"))
        );

        speculationSpread = new SpeculationSpread(
            address(contestOracleResolved)
        );

        speculationTotal = new SpeculationTotal(address(contestOracleResolved));

        speculationMoneyline = new SpeculationMoneyline(
            address(contestOracleResolved)
        );

        cfp = new CFPv1(
            address(DAOAddress),
            erc20,
            address(speculationSpread),
            address(speculationTotal),
            address(speculationMoneyline)
        );

        // transfer enough tokens to perform tests
        erc20.approve(address(this), 20 * 10 ** 6);
        erc20.transferFrom(address(this), address(alice), 20 * 10 ** 6);
        erc20.approve(address(this), 20 * 10 ** 6);
        erc20.transferFrom(address(this), address(bob), 20 * 10 ** 6);
        erc20.approve(address(this), 20 * 10 ** 6);
        erc20.transferFrom(address(this), address(carol), 20 * 10 ** 6);
        erc20.approve(address(this), 20 * 10 ** 6);
        erc20.transferFrom(address(this), address(cfp), 20 * 10 ** 6);

        currentContestCounter = contestOracleResolved.contestId();

        // Test contract approves the contestOracleResolved contract to spend LINK tokens on its behalf
        link.approve(address(contestOracleResolved), 0.25 * 10 * 10 ** 18);

        // create initial contest to be used with some tests (NotMatching, ScoredManually, Push)
        // for NotMatching test, currentContestCounter + 1
        // note: gasLimit (the last parameter below) is sent back as the request ID, therefore it should be/is unique
        contestOracleResolved.createContest(
            "53b3147442e62830726e95a89b9b3f28",
            "286108",
            "abc",
            "test1",
            "0x0",
            1234,
            300000
        );

        vm.startPrank(address(mockOracle));
        contestOracleResolved.exposed_fulfillRequest(
            bytes32(uint256(300000)),
            dummyVal
        );
        vm.stopPrank();
        
        // for ScoredManually tests, currentContestCounter + 2
        contestOracleResolved.createContest(
            "53b3147442e62830726e95a89b9b3f28",
            "286108",
            "abc",
            "test1",
            "0x0",
            1234,
            299999
        );

        vm.startPrank(address(mockOracle));
        contestOracleResolved.exposed_fulfillRequest(
            bytes32(uint256(299999)),
            dummyVal
        );
        vm.stopPrank();

        // for Push tests, currentContestCounter + 3
        contestOracleResolved.createContest(
            "53b3147442e62830726e95a89b9b3f28",
            "286108",
            "abc",
            "test1",
            "0x0",
            1234,
            299998
        );

        vm.startPrank(address(mockOracle));
        contestOracleResolved.exposed_fulfillRequest(
            bytes32(uint256(299998)),
            dummyVal
        );
        vm.stopPrank();

        // away side winning contest, currentContestCounter + 4
        contestOracleResolved.createContest(
            "53b3147442e62830726e95a89b9b3f28",
            "286108",
            "abc",
            "test1",
            "0x0",
            1234,
            299997
        );

        vm.startPrank(address(mockOracle));
        contestOracleResolved.exposed_fulfillRequest(
            bytes32(uint256(299997)),
            dummyVal
        );
        vm.stopPrank();

        // home side winning contest, currentContestCounter + 5
        contestOracleResolved.createContest(
            "53b3147442e62830726e95a89b9b3f28",
            "286108",
            "abc",
            "test1",
            "0x0",
            1234,
            299996
        );

        vm.startPrank(address(mockOracle));
        contestOracleResolved.exposed_fulfillRequest(
            bytes32(uint256(299996)),
            dummyVal
        );
        vm.stopPrank();

        // move forward in time so that contests can be scored
        vm.warp(block.timestamp + 3600);

        contestOracleResolved.scoreContest(currentContestCounter + 1, "test2", "0x0", 1234, 300000);

        vm.startPrank(address(mockOracle));
        contestOracleResolved.exposed_fulfillRequest(
            bytes32(uint256(300000)),
            // 16017
            abi.encodePacked(bytes32(0x0000000000000000000000000000000000000000000000000000000000003e91))
        );
        vm.stopPrank();

        contestOracleResolved.scoreContest(currentContestCounter + 2, "test2", "0x0", 1234, 299999);

        vm.startPrank(address(mockOracle));
        contestOracleResolved.exposed_fulfillRequest(
            bytes32(uint256(299999)),
            // 0
            abi.encodePacked(bytes32(0x0000000000000000000000000000000000000000000000000000000000000000))
        );
        vm.stopPrank();

        contestOracleResolved.scoreContest(currentContestCounter + 3, "test2", "0x0", 1234, 299998);

        vm.startPrank(address(mockOracle));
        contestOracleResolved.exposed_fulfillRequest(
            bytes32(uint256(299998)),
            // 16016
            abi.encodePacked(bytes32(0x0000000000000000000000000000000000000000000000000000000000003e90))
        );
        vm.stopPrank();

        contestOracleResolved.scoreContest(currentContestCounter + 4, "test2", "0x0", 1234, 299997);

        vm.startPrank(address(mockOracle));
        contestOracleResolved.exposed_fulfillRequest(
            bytes32(uint256(299997)),
            // 24016
            abi.encodePacked(bytes32(0x0000000000000000000000000000000000000000000000000000000000005dd0))
        );
        vm.stopPrank();

        contestOracleResolved.scoreContest(currentContestCounter + 5, "test2", "0x0", 1234, 299996);
        
        vm.startPrank(address(mockOracle));
        contestOracleResolved.exposed_fulfillRequest(
            bytes32(uint256(299996)),
            // 16024
            abi.encodePacked(bytes32(0x0000000000000000000000000000000000000000000000000000000000003e98))
        );
        vm.stopPrank();

        vm.warp(block.timestamp);

        // speculation(1), status is open
        cfp.createSpeculation(
            currentContestCounter + 1,
            uint32(block.timestamp + 365 days),
            address(speculationMoneyline),
            0
        );

        // speculation(2), status is open but timestamp is current time (or in the past)
        cfp.createSpeculation(
            currentContestCounter + 1,
            uint32(block.timestamp),
            address(speculationMoneyline),
            0
        );

        // speculation(3), status is locked despite the locktime being in the future (this is possible if the relayer locks)
        cfp.createSpeculation(
            currentContestCounter + 1,
            uint32(block.timestamp + 365 days),
            address(speculationMoneyline),
            0
        );

        // speculation(4) (locked, not closed)
        cfp.createSpeculation(
            currentContestCounter + 1,
            uint32(block.timestamp + 10 minutes),
            address(speculationMoneyline),
            0
        );

        // speculation(5)
        cfp.createSpeculation(
            currentContestCounter + 1,
            uint32(block.timestamp + 1 minutes),
            address(speculationMoneyline),
            0
        );

        // speculation(6)
        cfp.createSpeculation(
            currentContestCounter + 1,
            uint32(block.timestamp + 1 minutes),
            address(speculationMoneyline),
            0
        );

        // speculation(7) away side winner
        cfp.createSpeculation(
            currentContestCounter + 4,
            uint32(block.timestamp + 1 minutes),
            address(speculationMoneyline),
            0
        );

        // speculation(8) win side will be away
        cfp.createSpeculation(
            currentContestCounter + 4,
            uint32(block.timestamp + 1 minutes),
            address(speculationMoneyline),
            0
        );

        // speculation(9) win side will be home
        cfp.createSpeculation(
            currentContestCounter + 5,
            uint32(block.timestamp + 1 minutes),
            address(speculationMoneyline),
            0
        );

        // speculation(10) win side will be over
        cfp.createSpeculation(
            currentContestCounter + 4,
            uint32(block.timestamp + 1 minutes),
            address(speculationTotal),
            1
        );

        // speculation(11) win side will be under
        cfp.createSpeculation(
            currentContestCounter + 5,
            uint32(block.timestamp + 1 minutes),
            address(speculationTotal),
            99
        );

        // speculation(12), based on non-matching score
        // there are no longer "non-matching scores" as the DON responds with either a score or an error
        cfp.createSpeculation(
            currentContestCounter + 1,
            uint32(block.timestamp + 1 minutes),
            address(speculationMoneyline),
            0
        );

        // speculation(13), based on 0-0 score
        cfp.createSpeculation(
            currentContestCounter + 2,
            uint32(block.timestamp + 1 minutes),
            address(speculationMoneyline),
            0
        );

        // speculation(14), based on push
        cfp.createSpeculation(
            currentContestCounter + 3,
            uint32(block.timestamp + 1 minutes),
            address(speculationMoneyline),
            0
        );

        // speculation(15), based on forfeit
        cfp.createSpeculation(
            currentContestCounter + 3,
            uint32(block.timestamp + 1 minutes),
            address(speculationMoneyline),
            0
        );

        cfp.grantRole(bytes32(RELAYER_ROLE), address(this));

        speculationMoneyline.grantRole(
            bytes32(CONTEST_CONTRACT_ADDRESS),
            address(cfp)
        );

        speculationTotal.grantRole(
            bytes32(CONTEST_CONTRACT_ADDRESS),
            address(cfp)
        );

        contestOracleResolved.grantRole(bytes32(SCORE_MANAGER), address(vince));
        cfp.grantRole(bytes32(SCORE_MANAGER), address(vince));

        // carol taking both sides of speculations so these don't close when calling lock due to there being no action (on either side)
        vm.startPrank(carol);
        erc20.approve(address(cfp), 8 * 10 ** 6);
        cfp.createPosition(3, 1 * 10 ** 6, 1 * 10 ** 6, PositionType.Upper);
        cfp.createPosition(3, 1 * 10 ** 6, 1 * 10 ** 6, PositionType.Lower);
        cfp.createPosition(4, 1 * 10 ** 6, 1 * 10 ** 6, PositionType.Upper);
        cfp.createPosition(4, 1 * 10 ** 6, 1 * 10 ** 6, PositionType.Lower);
        vm.stopPrank();

        cfp.lockSpeculation(3);
        cfp.lockSpeculation(4);

        // alice positions for tests
        vm.startPrank(alice);
        erc20.approve(address(cfp), 19 * 10 ** 6);
        cfp.createPosition(5, 1 * 10 ** 6, 0, PositionType.Upper);
        cfp.createPosition(6, 1 * 10 ** 6, 0, PositionType.Upper);
        cfp.createPosition(7, 1 * 10 ** 6, 0, PositionType.Upper);
        cfp.createPosition(8, 2 * 10 ** 6, 0, PositionType.Upper);
        cfp.createPosition(9, 2 * 10 ** 6, 0, PositionType.Upper);
        cfp.createPosition(10, 2 * 10 ** 6, 0, PositionType.Upper);
        cfp.createPosition(11, 2 * 10 ** 6, 0, PositionType.Upper);
        // cfp.createPosition(12, 2 * 10 ** 6, 0, PositionType.Upper);
        cfp.createPosition(13, 2 * 10 ** 6, 0, PositionType.Upper);
        cfp.createPosition(14, 2 * 10 ** 6, 0, PositionType.Upper);
        cfp.createPosition(15, 2 * 10 ** 6, 0, PositionType.Upper);
        vm.stopPrank();

        // bob positions for tests
        vm.startPrank(bob);
        erc20.approve(address(cfp), 9 * 10 ** 6);
        cfp.createPosition(7, 1 * 10 ** 6, 0, PositionType.Lower);
        cfp.createPosition(8, 1 * 10 ** 6, 0, PositionType.Lower);
        cfp.createPosition(9, 1 * 10 ** 6, 0, PositionType.Lower);
        cfp.createPosition(10, 1 * 10 ** 6, 0, PositionType.Lower);
        cfp.createPosition(11, 1 * 10 ** 6, 0, PositionType.Lower);
        // cfp.createPosition(12, 1 * 10 ** 6, 0, PositionType.Lower);
        cfp.createPosition(13, 1 * 10 ** 6, 0, PositionType.Lower);
        cfp.createPosition(14, 1 * 10 ** 6, 0, PositionType.Lower);
        cfp.createPosition(15, 1 * 10 ** 6, 0, PositionType.Lower);
        vm.stopPrank();

        cfp.lockSpeculation(6);
        cfp.lockSpeculation(7);
        cfp.lockSpeculation(8);
        cfp.lockSpeculation(9);
        cfp.lockSpeculation(10);
        cfp.lockSpeculation(11);
        // cfp.lockSpeculation(12);
        cfp.lockSpeculation(13);
        cfp.lockSpeculation(14);

        vm.warp(block.timestamp + 3600); // move forward in time 6 minutes, must be long enough to exceed timeout
        cfp.scoreSpeculation(7);
        cfp.scoreSpeculation(8);

        // zero zero score must be verified
        cfp.scoreSpeculation(9);

        cfp.scoreSpeculation(10);

        // zero zero score must be verified
        cfp.scoreSpeculation(11);
        
        cfp.scoreSpeculation(14);
        vm.warp(block.timestamp);

    }

    function testSpeculationShouldCorrectlyReflectBalances() public {
        // create positions on speculation 1, ensure that the speculation reflects accurate balances
        vm.startPrank(alice);
        erc20.approve(address(cfp), 1 * 10 ** 6);
        cfp.createPosition(1, 1 * 10 ** 6, 0, PositionType.Upper);
        vm.stopPrank();
        vm.startPrank(bob);
        erc20.approve(address(cfp), 2 * 10 ** 6);
        cfp.createPosition(1, 2 * 10 ** 6, 0, PositionType.Lower);
        vm.stopPrank();

        (, uint256 upper1, uint256 lower1, , , , , , ) = cfp.speculations(1);
        assertEq(upper1, 1 * 10 ** 6);
        assertEq(lower1, 2 * 10 ** 6);
    }

    function testShouldRevertWhenClaimingBeforeSpeculationIsClosed() public {
        // you cannot claim when the speculation has not started
        vm.expectRevert(
            abi.encodeWithSignature("SpeculationStatusIsNotClosed(uint256)", 1)
        );
        vm.startPrank(alice);
        cfp.claim(1, 0);
        vm.stopPrank();

        // you cannot claim if the contest has not yet gone final, even if you have a position
        vm.expectRevert(
            abi.encodeWithSignature("SpeculationStatusIsNotClosed(uint256)", 4)
        );
        vm.startPrank(alice);
        cfp.claim(4, 0);
        vm.stopPrank();
    }

    function testShouldRevertWhenAttemptingToCreatePositionAfterSpeculationHasBegun()
        public
    {
        // you cannot create a position after the speculation has begun, based on either blocktime or locked status
        vm.expectRevert(
            abi.encodeWithSignature("SpeculationHasStarted(uint256)", 2)
        );
        vm.startPrank(alice);
        cfp.createPosition(2, 1 * 10 ** 6, 0, PositionType.Upper);
        vm.stopPrank();

        vm.expectRevert(
            abi.encodeWithSignature("SpeculationHasStarted(uint256)", 3)
        );
        vm.startPrank(alice);
        cfp.createPosition(3, 1 * 10 ** 6, 0, PositionType.Upper);
        vm.stopPrank();
    }

    function testClaimingIsNotAllowedWhenAllPositionsAreOnSameSideUntilWinSideIsInvalid()
        public
    {
        vm.warp(block.timestamp + 120); // go forward in time 120 seconds, speculation 5 now has a locktime in the past but is still open
        vm.expectRevert(
            abi.encodeWithSignature("SpeculationStatusIsNotClosed(uint256)", 5)
        );
        vm.startPrank(alice);
        cfp.claim(5, 0);
        vm.stopPrank();

        // speculation 6 is closed (has been locked/closed, all positions on same side)
        uint256 aliceBalance = erc20.balanceOf(alice);
        (, uint256 upper6, , , , , , , ) = cfp.speculations(6);
        vm.startPrank(alice);
        cfp.claim(6, 0);
        vm.stopPrank();
        assertEq(aliceBalance + 1 * 10 ** 6, aliceBalance + upper6);
    }

    function testClaimingShouldBePermittedByCorrectUser() public {
        uint256 aliceBalance = erc20.balanceOf(alice);
        (, uint256 upper7, uint256 lower7, , , , , , ) = cfp.speculations(7);
        vm.startPrank(alice);
        cfp.claim(7, 0);
        vm.stopPrank();
        assertEq(aliceBalance + 2 * 10 ** 6, aliceBalance + upper7 + lower7);

        // bob lost
        vm.expectRevert(
            abi.encodeWithSignature("IneligibleForWinnings(uint256)", 7)
        );
        vm.startPrank(bob);
        cfp.claim(7, 0);
        vm.stopPrank();
    }

    function testShouldRevertWhenAttemptingToClaimTwice() public {
        uint256 aliceBalance = erc20.balanceOf(alice);
        (, uint256 upper7, uint256 lower7, , , , , , ) = cfp.speculations(7);
        vm.startPrank(alice);
        cfp.claim(7, 0);
        vm.stopPrank();
        assertEq(aliceBalance + 2 * 10 ** 6, aliceBalance + upper7 + lower7);

        vm.expectRevert(
            abi.encodeWithSignature("WinningsAlreadyClaimed(uint256)", 7)
        );
        vm.startPrank(alice);
        cfp.claim(7, 0);
        vm.stopPrank();
    }

    function testBasicClaimFunctionality() public {
        // below is the state of speculations and positions relevant to the test

        // speculations[8] and positions[8] is a speculation graded as away team won (upper should claim all)
        // speculations[8] = Speculation(
        //     8,
        //     2 * 10**6,
        //     1 * 10**6,
        //     uint32(block.timestamp),
        //     address(0x0),
        //     0,
        //     address(0x0),
        //     SpeculationStatus.Closed,
        //     WinSide.Away
        // );

        // positions[8][address(0x1)] = Position(2 * 10**6, 0, false); // winner
        // positions[8][address(0x2)] = Position(0, 1 * 10**6, false); // loser

        // speculations[9] and positions[9] is a speculation graded as home team won (lower should claim all)
        // speculations[9] = Speculation(
        //     9,
        //     2 * 10**6,
        //     1 * 10**6,
        //     uint32(block.timestamp),
        //     address(0x0),
        //     0,
        //     address(0x0),
        //     SpeculationStatus.Closed,
        //     WinSide.Home
        // );

        // positions[9][address(0x1)] = Position(2 * 10**6, 0, false); // loser
        // positions[9][address(0x2)] = Position(0, 1 * 10**6, false); // winner

        // speculations[10] and positions[10] is a speculation graded as over won (upper should claim all)
        // speculations[10] = Speculation(
        //     10,
        //     2 * 10**6,
        //     1 * 10**6,
        //     uint32(block.timestamp),
        //     address(0x0),
        //     0,
        //     address(0x0),
        //     SpeculationStatus.Closed,
        //     WinSide.Over
        // );

        // positions[10][address(0x1)] = Position(2 * 10**6, 0, false); // winner
        // positions[10][address(0x2)] = Position(0, 1 * 10**6, false); // loser

        // speculations[11] and positions[11] is a speculation graded as over won (lower should claim all)
        // speculations[11] = Speculation(
        //     11,
        //     2 * 10**6,
        //     1 * 10**6,
        //     uint32(block.timestamp),
        //     address(0x0),
        //     0,
        //     address(0x0),
        //     SpeculationStatus.Closed,
        //     WinSide.Under
        // );

        // positions[11][address(0x1)] = Position(2 * 10**6, 0, false); // lower
        // positions[11][address(0x2)] = Position(0, 1 * 10**6, false); // winner

        uint256 aliceBalance = erc20.balanceOf(alice);
        uint256 bobBalance = erc20.balanceOf(bob);
        (, uint256 upper8, uint256 lower8, , , , , , ) = cfp.speculations(8);
        (, uint256 upper9, uint256 lower9, , , , , , ) = cfp.speculations(9);
        (, uint256 upper10, uint256 lower10, , , , , , ) = cfp.speculations(10);
        (, uint256 upper11, uint256 lower11, , , , , , ) = cfp.speculations(11);
        vm.startPrank(alice);
        cfp.claim(8, 0);
        vm.expectRevert(
            abi.encodeWithSignature("IneligibleForWinnings(uint256)", 9)
        );
        cfp.claim(9, 0);
        cfp.claim(10, 0);
        vm.expectRevert(
            abi.encodeWithSignature("IneligibleForWinnings(uint256)", 11)
        );
        cfp.claim(11, 0);
        vm.stopPrank();
        vm.startPrank(bob);
        vm.expectRevert(
            abi.encodeWithSignature("IneligibleForWinnings(uint256)", 8)
        );
        cfp.claim(8, 0);
        cfp.claim(9, 0);
        vm.expectRevert(
            abi.encodeWithSignature("IneligibleForWinnings(uint256)", 10)
        );
        cfp.claim(10, 0);
        cfp.claim(11, 0);
        vm.stopPrank();
        assertEq(
            aliceBalance + 6 * 10 ** 6,
            aliceBalance + upper8 + lower8 + upper10 + lower10
        );
        assertEq(
            bobBalance + 6 * 10 ** 6,
            bobBalance + upper9 + lower9 + upper11 + lower11
        );
    }

    function testZeroZeroContestShouldBehaveAccordingly() public {
        // zero-zero score must be checked/confirmed by score manager

        vm.warp(block.timestamp + 3600);
        vm.expectRevert(
            abi.encodeWithSignature("ZeroZeroScoreMustBeVerified()")
        );
        cfp.scoreSpeculation(13);

        // confirm that status is actually RequiresConfirmation
        (, , , ContestStatus contestStatus2a, , ,) = contestOracleResolved
            .contests(2);
        assertEq(uint8(contestStatus2a), 5);

        // attempt to score with score manager
        vm.startPrank(vince);
        contestOracleResolved.scoreContestManually(2, 0, 0);
        (, , , ContestStatus contestStatus2b, , ,) = contestOracleResolved
            .contests(2);
        assertEq(uint8(contestStatus2b), 4);
        vm.stopPrank();

        cfp.scoreSpeculation(13);
        uint256 aliceBalance = erc20.balanceOf(alice);
        uint256 bobBalance = erc20.balanceOf(bob);
        (, uint256 upper13, uint256 lower13, , , , , , ) = cfp.speculations(13);
        vm.startPrank(alice);
        cfp.claim(13, 0);
        vm.stopPrank();
        vm.startPrank(bob);
        cfp.claim(13, 0);
        vm.stopPrank();
        assertEq(aliceBalance + 2 * 10 ** 6, aliceBalance + upper13);
        assertEq(bobBalance + 1 * 10 ** 6, bobBalance + lower13);
    }

    function testPushShouldResultInMoneylinePayoutsBeingReturned() public {
        uint256 aliceBalance = erc20.balanceOf(alice);
        uint256 bobBalance = erc20.balanceOf(bob);
        (, uint256 upper14, uint256 lower14, , , , , , ) = cfp.speculations(14);
        vm.startPrank(alice);
        cfp.claim(14, 0);
        vm.stopPrank();
        vm.startPrank(bob);
        cfp.claim(14, 0);
        vm.stopPrank();
        assertEq(aliceBalance + 2 * 10 ** 6, aliceBalance + upper14);
        assertEq(bobBalance + 1 * 10 ** 6, bobBalance + lower14);
    }

    function testForfeitShouldAllowAllPartiesToGetTheirFundsBack() public {
        vm.startPrank(vince);
        cfp.forfeitSpeculation(15);
        vm.stopPrank();

        uint256 aliceBalance = erc20.balanceOf(alice);
        uint256 bobBalance = erc20.balanceOf(bob);
        (, uint256 upper15, uint256 lower15, , , , , , ) = cfp.speculations(15);
        vm.startPrank(alice);
        cfp.claim(15, 0);
        vm.stopPrank();
        vm.startPrank(bob);
        cfp.claim(15, 0);
        vm.stopPrank();
        assertEq(aliceBalance + 2 * 10 ** 6, aliceBalance + upper15);
        assertEq(bobBalance + 1 * 10 ** 6, bobBalance + lower15);
    }

    function testContributionsShouldIncrementDAO() public {
        // DAO address should start with 4 from carol contributions
        uint256 DAOBalance1 = erc20.balanceOf(DAOAddress);
        assertEq(DAOBalance1, 4 * 10 ** 6);

        vm.startPrank(alice);
        cfp.claim(14, 1 * 10 ** 6);
        vm.stopPrank();

        uint256 DAOBalance2 = erc20.balanceOf(DAOAddress);
        assertEq(DAOBalance2, 5 * 10 ** 6);
    }

    function testShouldRevertWhenAttemptingToVoidWithoutVoidTimePassing()
        public
    {
        for (uint256 i = 0; i < 14; i++) {
            vm.expectRevert(
                abi.encodeWithSignature(
                    "SpeculationMayNotBeVoided(uint256)",
                    i + 1
                )
            );
            cfp.voidSpeculation(i + 1);
        }
    }

    function testNonMatchingSourceCodeShouldFail() public {

        // transfer LINK token to contract harness so contests this one contest can be created and scored
        link.approve(address(contestOracleResolved), 0.25 * 2 * 10 ** 18);

        vm.expectRevert(abi.encodeWithSignature("IncorrectHash()"));
        contestOracleResolved.createContest(
            "53b3147442e62830726e95a89b9b3f28",
            "286108",
            "abc",
            "test2",
            "0x0",
            1234,
            299995
        );

        currentContestCounter = contestOracleResolved.contestId();

        // should pass
        contestOracleResolved.createContest(
            "53b3147442e62830726e95a89b9b3f28",
            "286108",
            "abc",
            "test1",
            "0x0",
            1234,
            299995
        );

        vm.startPrank(address(mockOracle));
        
        contestOracleResolved.exposed_fulfillRequest(
            bytes32(uint256(299995)),
            dummyVal
        );

        vm.stopPrank();

        // move forward in time so that contests can be scored
        vm.warp(block.timestamp + 3600);

        vm.expectRevert(abi.encodeWithSignature("IncorrectHash()"));
        contestOracleResolved.scoreContest(currentContestCounter + 1, "test1", "0x0", 1234, 299995);

        // should pass
        contestOracleResolved.scoreContest(currentContestCounter + 1, "test2", "0x0", 1234, 299995);

    }

    function testAnyUserShouldBeAbleToCreateOrScoreAContestProvidedTheyHaveLink()
        public
    {

        // Transfer LINK tokens from the contract to the user's address
        // link.transfer(vince, 0.25 * 2 * 10 ** 18);
        link.transfer(vince, 0.004 * 2 * 10 ** 18); // mainnet LINK requirement

        vm.startPrank(vince);

        // should error
        vm.expectRevert();
        contestOracleResolved.createContest(
            "53b3147442e62830726e95a89b9b3f28",
            "286108",
            "abc",
            "test1",
            "0x0",
            1234,
            299994
        );

        // User (vince) approves the contract to spend LINK on their behalf
        // link.approve(address(contestOracleResolved), 0.25 * 1 * 10 ** 18);
        link.approve(address(contestOracleResolved), 0.004 * 1 * 10 ** 18); // mainnet LINK requirement

        // should pass
        contestOracleResolved.createContest(
            "53b3147442e62830726e95a89b9b3f28",
            "286108",
            "abc",
            "test1",
            "0x0",
            1234,
            299994
        );

        vm.stopPrank();

        vm.startPrank(address(mockOracle));

        contestOracleResolved.exposed_fulfillRequest(
            bytes32(uint256(299994)),
            dummyVal
        );

        vm.stopPrank();

        vm.warp(block.timestamp + 3600);

        vm.startPrank(vince);

        // should error
        vm.expectRevert();
        contestOracleResolved.scoreContest(currentContestCounter + 6, "test2", "0x0", 1234, 299994);

        // link.approve(address(contestOracleResolved), 0.25 * 1 * 10 ** 18);
        link.approve(address(contestOracleResolved), 0.004 * 1 * 10 ** 18); // mainnet LINK requirement

        // should pass
        contestOracleResolved.scoreContest(currentContestCounter + 6, "test2", "0x0", 1234, 299994);

        vm.stopPrank();

    }
}
