// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

/**
 * @title SpeculationMoneyline
 * @author ospex.org
 * @notice This contract is part of the ospex dApp, deployed on Polygon Mainnet.
 * @notice alt url: ospex.crypto
 * @dev The contract contains logic for scoring moneyline speculations for ospex.
 * For more information, visit ospex.org or the project repository at github.com/ospex-org
 */

import "../lib/openzeppelin-contracts/contracts/access/AccessControl.sol";
import "./CFPStructs.sol";

interface IContestScorer {
    function getContest(uint256 _contestId) external view returns (Contest memory);
}

contract SpeculationMoneyline is AccessControl {

    // If both away team score and home team score are zero, final score must be confirmed
    // by executing scoreContestManually function (SCOREMANAGER_ROLE required to do this)
    error ZeroZeroScoreMustBeVerified();

    // Pre-CL Functions, scores were returned from multiple oracles and compared via the contract
    // Post-CL Functions, the DON will return an error if scores do not match
    // contests likely will never end up in this status; as of current deployment, this is a deprecated status
    error NonMatchingScoreFromOracles();

    // Contest has yet to be scored and is likely still in progress, or APIs do not have a score available
    error ScoreNotFinalized(uint256 contestId);

    // Create role for contest contract address as this will be the only address calling this contract
    bytes32 public constant CONTEST_CONTRACT_ADDRESS =
        keccak256("CONTEST_CONTRACT_ADDRESS");
    // Create role for manager of contest address
    bytes32 public constant SCOREMANAGER_ROLE = keccak256("SCOREMANAGER_ROLE");

    // Address of ContestOracleResolved contract
    address public ContestScorer;

    /**
     * @notice Executes once when a contract is created to initialize state variables
     *
     * @param _contestScorer Address of ContestOracleResolved contract
     */
    constructor(address _contestScorer) {
        ContestScorer = _contestScorer;
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
    }

    // Ensures contest final score (as returned from the DON) is not 0-0, which would be unlikely for the four major US sports
    // If/when soccer is added, this may need to be revised
    modifier nonZeroScoreContestResult(
        uint32 _awayScore,
        uint32 _homeScore,
        ContestStatus _contestStatus
    ) {
        if (_contestStatus == ContestStatus.NotMatching) {
            revert NonMatchingScoreFromOracles();
        } else if (
            _awayScore + _homeScore == 0 &&
            !(_contestStatus == ContestStatus.ScoredManually)
        ) {
            revert ZeroZeroScoreMustBeVerified();
        }
        _;
    }

    /**
    * @notice Execute function to determine winning team of moneyline speculation
    *
    * @param _contestId Contest id to identify the correct contest struct
    * @param _theNumber Unused; moneyline is simply which team won (which team scored more goals/points/runs)
    */
    function determineWinSide(
        uint256 _contestId,
        int32 _theNumber
    )
        external
        view
        onlyRole(CONTEST_CONTRACT_ADDRESS)
        nonZeroScoreContestResult(
            IContestScorer(ContestScorer).getContest(_contestId).awayScore,
            IContestScorer(ContestScorer).getContest(_contestId).homeScore,
            IContestScorer(ContestScorer).getContest(_contestId).contestStatus
        )
        returns (WinSide)
    {
        Contest memory contest = IContestScorer(ContestScorer).getContest(_contestId);
        if (
            !(contest.contestStatus == ContestStatus.Scored ||
                contest.contestStatus == ContestStatus.ScoredManually)
        ) {
            revert ScoreNotFinalized(_contestId);
        }
        return scoreMoneyline(contest.awayScore, contest.homeScore);
    }

    /**
    * @notice Determine winning side of a moneyline speculation and return result
    *
    * @param _awayScore Away team score
    * @param _homeScore Home team score
    */
    function scoreMoneyline(
        uint32 _awayScore,
        uint32 _homeScore
    ) private pure returns (WinSide) {
        if (_awayScore > _homeScore) {
            return WinSide.Away;
        } else if (_homeScore > _awayScore) {
            return WinSide.Home;
        } else {
            return WinSide.Push;
        }
    }

    /**
    * @notice If ContestOracleResolved address is different than what was passed into the constructor, it can be updated with this function
    *
    * @param _address Address of ContestOracleResolved contract
    */
    function setContractInterfaceAddress(
        address _address
    ) external onlyRole(SCOREMANAGER_ROLE) {
        ContestScorer = _address;
    }
}
