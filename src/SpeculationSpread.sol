// SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;

import "../lib/openzeppelin-contracts/contracts/access/AccessControl.sol";
import "./CFPStructs.sol";

interface IContestScorer {
    function getContest(uint256 _contestId) external view returns (Contest memory);
}

contract SpeculationSpread is AccessControl {

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
        } else if (_awayScore + _homeScore == 0) {
            revert ZeroZeroScoreMustBeVerified();
        }
        _;
    }

    /**
    * @notice Execute function to determine winning side of speculation based on a point spread
    *
    * @param _contestId Contest id to identify the correct contest struct
    * @param _theNumber Point spread value
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
        return scoreSpread(contest.awayScore, contest.homeScore, _theNumber);
    }

    /**
    * @notice Determine winning side of a point spread speculation and return result
    *
    * @param _awayScore Away team score
    * @param _homeScore Home team score
    * @param _theNumber Point spread value. Represents the number of points by which the away team is expected to win or lose.
    *                   Positive values indicate the away team is favored and must win by more than this value to cover the spread.
    *                   Negative values indicate the home team is favored, and the away team must either win outright or lose by fewer than the absolute value to cover the spread.
    *                   For example:
    *                   - If _theNumber is 3, the away team must win by more than 3 points/goals/runs.
    *                   - If _theNumber is -4, the away team must either win outright or lose by fewer than 4 points/goals/runs.
    */
    function scoreSpread(
        uint32 _awayScore,
        uint32 _homeScore,
        int32 _theNumber
    ) private pure returns (WinSide) {
        if (int32(_awayScore) + _theNumber >= int32(_homeScore)) {
            return WinSide.Away;
        } else {
            return WinSide.Home;
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
