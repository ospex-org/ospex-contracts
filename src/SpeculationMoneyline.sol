// SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;

import "../lib/openzeppelin-contracts/contracts/access/AccessControl.sol";
import "./CFPStructs.sol";

interface IContestScorer {
    function getContest(uint256 _contestId) external view returns (Contest memory);
}

contract SpeculationMoneyline is AccessControl {
    error ZeroZeroScoreMustBeVerified();
    error NonMatchingScoreFromOracles();
    error ScoreNotFinalized(uint256 contestId);

    // create role for contest contract address as this will be the only address calling this contract
    bytes32 public constant CONTEST_CONTRACT_ADDRESS =
        keccak256("CONTEST_CONTRACT_ADDRESS");
    // create role for manager of contest address
    bytes32 public constant SCOREMANAGER_ROLE = keccak256("SCOREMANAGER_ROLE");

    address public ContestScorer;

    constructor(address _contestScorer) {
        ContestScorer = _contestScorer;
    }

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

    // set the interface address for the current contest logic
    function setContractInterfaceAddress(
        address _address
    ) external onlyRole(SCOREMANAGER_ROLE) {
        ContestScorer = _address;
    }
}
