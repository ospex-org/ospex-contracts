// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "@openzeppelin/contracts/access/AccessControl.sol";
import "@chainlink/contracts/src/v0.8/ChainlinkClient.sol";
import "./CFPStructs.sol";

contract ContestOracleResolved is AccessControl, ChainlinkClient {
    using Chainlink for Chainlink.Request;

    error TimerHasNotExpired(uint256 contestId);
    error ScoreContestNotInReadyStatus(uint256 contestId);
    error OracleJobsNotDifferent(uint8 oracle1, uint8 oracle2);
    error ContestUnableToBeScoredManually(uint256 contestId);

    // role for scoring contests manually, changing fees or changing the timer interval
    bytes32 public constant SCOREMANAGER_ROLE = keccak256("SCOREMANAGER_ROLE");

    // contest counter
    uint256 public contestId = 1;

    // oracle counter (starts at 4, 0-3 set during contract deployment)
    uint8 public oracleId = 4;

    // timer for attempting to score - can only attempt every x interval
    uint256 public contestTimerInterval = 4 minutes;

    // unique id for each contest
    mapping(uint256 => Contest) public contests;

    // unique id for each oracle
    mapping(uint8 => Oracle) public oracles;

    // timer for calling score contest function
    mapping(uint256 => uint256) public contestTimers;

    // timer for voiding contest that is unable to be scored
    mapping(uint256 => uint256) public contestCreationTime;

    // requestMapping necessary for comparing oracle results
    mapping(bytes32 => uint256) public requestMapping;

    // contest creation mappings, these must equal or contest will not be created
    mapping(uint256 => uint64) public contestCriteria1;
    mapping(uint256 => uint64) public contestCriteria2;

    event ContestCreated(
        uint256 indexed id,
        string rundownId,
        string sportspageId,
        address contestCreator,
        uint64 contestCriteria
    );
    event ContestScored(uint256 indexed id, uint32 awayScore, uint32 homeScore);

    constructor(address _link) {
        setChainlinkToken(_link);

        // contest creation validation (goerli chainlink oracle is address below)
        oracles[0] = Oracle(
            0xE65D6dd7336Ef4BF77Ce07Ee39ab920f4144Bb6B,
            "939af01beb1d431590c2a1a4a6768aa3",
            0.01 * 10 ** 18
        );
        oracles[1] = Oracle(
            0xE65D6dd7336Ef4BF77Ce07Ee39ab920f4144Bb6B,
            "6674ff7c08d7431e869f3b889fb23d92",
            0.01 * 10 ** 18
        );

        // contest scoring (goerli chainlink oracle is address below)
        oracles[2] = Oracle(
            0xE65D6dd7336Ef4BF77Ce07Ee39ab920f4144Bb6B,
            "856f4dd1f8654752b36e34cfdea09f9d",
            0.01 * 10 ** 18
        );
        oracles[3] = Oracle(
            0xE65D6dd7336Ef4BF77Ce07Ee39ab920f4144Bb6B,
            "f407a57d172a456486809b6a4a5f06bd",
            0.01 * 10 ** 18
        );

        _setupRole(DEFAULT_ADMIN_ROLE, msg.sender);
    }

    // scoreContest can only be called if the current time is [contestTimer] greater than the last time the function was called
    modifier timerExpired(uint256 _id) {
        if (contestTimers[_id] + contestTimerInterval >= block.timestamp) {
            revert TimerHasNotExpired(_id);
        }
        _;
    }

    modifier scoreContestReadyStatus(uint256 _id) {
        if (
            !(contests[_id].contestStatus == ContestStatus.Verified ||
                contests[_id].contestStatus == ContestStatus.Pending ||
                contests[_id].contestStatus == ContestStatus.NotMatching)
        ) {
            revert ScoreContestNotInReadyStatus(_id);
        }
        _;
    }

    modifier oracleJobsMustBeDifferent(uint8 _oracle1, uint8 _oracle2) {
        if (oracles[_oracle1].jobId == oracles[_oracle2].jobId) {
            revert OracleJobsNotDifferent(_oracle1, _oracle2);
        }
        _;
    }

    // call oracles to ensure the contest API ids are referencing the same contest
    function setContestCriteriaMappings(
        string memory _rundownId,
        string memory _sportspageId,
        uint256 _id,
        uint8 _oracle1,
        uint8 _oracle2
    ) internal oracleJobsMustBeDifferent(_oracle1, _oracle2) {
        requestCriteria(
            _rundownId,
            oracles[_oracle1].oracleAddress,
            oracles[_oracle1].jobId,
            oracles[_oracle1].fee,
            _id
        );
        requestCriteria(
            _sportspageId,
            oracles[_oracle2].oracleAddress,
            oracles[_oracle2].jobId,
            oracles[_oracle2].fee,
            _id
        );
    }

    function requestCriteria(
        string memory _id,
        address _oracle,
        bytes32 _jobId,
        uint256 _fee,
        uint256 _cid
    ) internal {
        Chainlink.Request memory req = buildChainlinkRequest(
            _jobId,
            address(this),
            this.fulfillCriteria.selector
        );
        req.add("id", _id);
        bytes32 requestId = sendChainlinkRequestTo(_oracle, req, _fee);
        requestMapping[requestId] = _cid;
    }

    function fulfillCriteria(
        bytes32 _requestId,
        uint64 _result
    ) public recordChainlinkFulfillment(_requestId) {
        // rounds result to nearest hour for comparison, in case the APIs have slightly different start times
        uint64 roundedResult = _result - ((_result % (1 * 10 ** 10)) % 3600);
        Contest storage contestToUpdate = contests[requestMapping[_requestId]];
        if (contestCriteria1[requestMapping[_requestId]] == 0x0) {
            contestCriteria1[requestMapping[_requestId]] = roundedResult;
        } else {
            contestCriteria2[requestMapping[_requestId]] = roundedResult;
        }
        if (
            contestCriteria1[requestMapping[_requestId]] != 0x0 &&
            contestCriteria1[requestMapping[_requestId]] ==
            contestCriteria2[requestMapping[_requestId]]
        ) {
            contestToUpdate.contestStatus = ContestStatus.Verified;
            emit ContestCreated(
                requestMapping[_requestId],
                contestToUpdate.rundownId,
                contestToUpdate.sportspageId,
                contestToUpdate.contestCreator,
                _result
            );
        }
    }

    function scoreContest(
        uint256 _id
    ) external timerExpired(_id) scoreContestReadyStatus(_id) {
        contestTimers[_id] = block.timestamp;
        Contest storage contestToUpdate = contests[_id];
        // if scoreContest is running again and the status is pending, one of the oracles failed to return a result
        if (contestToUpdate.contestStatus == ContestStatus.Pending) {
            contestToUpdate.contestStatus = ContestStatus.Verified;
        }
        requestScore(
            contestToUpdate.rundownId,
            oracles[contestToUpdate.scoringOracles[0]].oracleAddress,
            oracles[contestToUpdate.scoringOracles[0]].jobId,
            oracles[contestToUpdate.scoringOracles[0]].fee,
            _id
        );
        requestScore(
            contestToUpdate.sportspageId,
            oracles[contestToUpdate.scoringOracles[1]].oracleAddress,
            oracles[contestToUpdate.scoringOracles[1]].jobId,
            oracles[contestToUpdate.scoringOracles[1]].fee,
            _id
        );
    }

    // initial request (Chainlink oracle function)
    function requestScore(
        string memory _id,
        address _oracle,
        bytes32 _jobId,
        uint256 _fee,
        uint256 _cid
    ) internal {
        Chainlink.Request memory req = buildChainlinkRequest(
            _jobId,
            address(this),
            this.fulfillScore.selector
        );
        req.add("id", _id);
        bytes32 requestId = sendChainlinkRequestTo(_oracle, req, _fee);
        requestMapping[requestId] = _cid;
    }

    // callback function (Chainlink oracle function)
    function fulfillScore(
        bytes32 _requestId,
        uint32 _result
    ) public recordChainlinkFulfillment(_requestId) {
        Contest storage contestToUpdate = contests[requestMapping[_requestId]];
        uint32[2] memory contestScore = uintToResultScore(_result);
        if (
            contestToUpdate.contestStatus == ContestStatus.Verified ||
            contestToUpdate.contestStatus == ContestStatus.NotMatching
        ) {
            contestToUpdate.awayScore = contestScore[0];
            contestToUpdate.homeScore = contestScore[1];
            contestToUpdate.contestStatus = ContestStatus.Pending;
        } else if (
            contestToUpdate.contestStatus == ContestStatus.Pending &&
            (contestToUpdate.awayScore != contestScore[0] ||
                contestToUpdate.homeScore != contestScore[1])
        ) {
            contestToUpdate.awayScore = 0;
            contestToUpdate.homeScore = 0;
            contestToUpdate.contestStatus = ContestStatus.NotMatching;
        } else if (
            contestToUpdate.contestStatus == ContestStatus.Pending &&
            (contestToUpdate.awayScore +
                contestToUpdate.homeScore +
                contestScore[0] +
                contestScore[1] ==
                0)
        ) {
            contestToUpdate.contestStatus = ContestStatus.RequiresConfirmation;
        } else {
            contestToUpdate.contestStatus = ContestStatus.Scored;
            emit ContestScored(
                requestMapping[_requestId],
                contestToUpdate.awayScore,
                contestToUpdate.homeScore
            );
        }
    }

    // Score contest manually - only possible if contestStatus is NotMatching or RequiresConfirmation (for 0-0 contests)
    function scoreContestManually(
        uint256 _id,
        uint32 _awayScore,
        uint32 _homeScore
    ) external onlyRole(SCOREMANAGER_ROLE) {
        if (
            contests[_id].contestStatus != ContestStatus.NotMatching &&
            contests[_id].contestStatus != ContestStatus.RequiresConfirmation
        ) {
            revert ContestUnableToBeScoredManually(_id);
        }
        Contest storage contestToUpdate = contests[_id];
        contestToUpdate.awayScore = _awayScore;
        contestToUpdate.homeScore = _homeScore;
        contestToUpdate.contestStatus = ContestStatus.ScoredManually;
        emit ContestScored(_id, _awayScore, _homeScore);
    }

    function createContest(
        string memory _rundownId,
        string memory _sportspageId,
        uint8 _oracleForCreationValidation1,
        uint8 _oracleForCreationValidation2,
        uint8 _oracleForContestScoring1,
        uint8 _oracleForContestScoring2
    )
        external
        oracleJobsMustBeDifferent(
            _oracleForCreationValidation1,
            _oracleForCreationValidation2
        )
        oracleJobsMustBeDifferent(
            _oracleForContestScoring1,
            _oracleForContestScoring2
        )
    {
        setContestCriteriaMappings(
            _rundownId,
            _sportspageId,
            contestId,
            _oracleForCreationValidation1,
            _oracleForCreationValidation2
        );
        Contest storage contest = contests[contestId];
        contestTimers[contestId] = block.timestamp; // initiated timer value upon contest creation
        contestCreationTime[contestId] = block.timestamp; // initiated timer value used to void after void time if contest unable to be scored
        contest.rundownId = _rundownId;
        contest.sportspageId = _sportspageId;
        contest.awayScore = 0;
        contest.homeScore = 0;
        contest.contestCreator = msg.sender;
        contest.scoringOracles[0] = _oracleForContestScoring1;
        contest.scoringOracles[1] = _oracleForContestScoring2;
        contestId++;
    }

    // return contest, utilized by interface
    function getContest(uint256 _id) public view returns (Contest memory) {
        return contests[_id];
    }

    function createOracle(
        address _oracleAddress,
        bytes32 _jobId,
        uint256 _fee
    ) external {
        Oracle storage oracle = oracles[oracleId];
        oracle.oracleAddress = _oracleAddress;
        oracle.jobId = _jobId;
        oracle.fee = _fee;
        oracleId++;
    }

    function updateFee(
        uint8 _oracle,
        uint256 _fee
    ) external onlyRole(SCOREMANAGER_ROLE) {
        Oracle storage oracle = oracles[_oracle];
        oracle.fee = _fee;
    }

    function updateTimer(
        uint256 _newContestTimerInterval
    ) external onlyRole(SCOREMANAGER_ROLE) {
        contestTimerInterval = _newContestTimerInterval;
    }

    // converts uint response to contest score
    function uintToResultScore(
        uint32 _uint
    ) internal pure returns (uint32[2] memory) {
        uint32[2] memory scoreArr;
        scoreArr[1] = _uint % 1000;
        scoreArr[0] = (_uint - scoreArr[1]) / 1000;
        return scoreArr;
    }
}
