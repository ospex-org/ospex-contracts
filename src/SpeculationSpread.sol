// SPDX-License-Identifier: MIT
pragma solidity >=0.8.0 <0.9.0;

import "@openzeppelin/contracts/access/AccessControl.sol";
import "./CFPStructs.sol";

interface IContestScorer {
    function getContest(uint256 _id) external view returns (Contest memory);
}

contract SpeculationSpread is AccessControl {
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
        _setupRole(DEFAULT_ADMIN_ROLE, msg.sender);
        ContestScorer = _contestScorer;
    }

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

    function determineWinSide(
        uint256 _id,
        int32 _theNumber
    )
        external
        view
        onlyRole(CONTEST_CONTRACT_ADDRESS)
        nonZeroScoreContestResult(
            IContestScorer(ContestScorer).getContest(_id).awayScore,
            IContestScorer(ContestScorer).getContest(_id).homeScore,
            IContestScorer(ContestScorer).getContest(_id).contestStatus
        )
        returns (WinSide)
    {
        Contest memory contest = IContestScorer(ContestScorer).getContest(_id);
        if (
            !(contest.contestStatus == ContestStatus.Scored ||
                contest.contestStatus == ContestStatus.ScoredManually)
        ) {
            revert ScoreNotFinalized(_id);
        }
        return scoreSpread(contest.awayScore, contest.homeScore, _theNumber);
    }

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

    // set the interface address for the current contest logic
    function setContractInterfaceAddress(
        address _address
    ) external onlyRole(SCOREMANAGER_ROLE) {
        ContestScorer = _address;
    }
}
