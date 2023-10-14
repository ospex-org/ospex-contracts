// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {FunctionsClient} from "@chainlink/src/v0.8/functions/dev/v1_0_0/FunctionsClient.sol";
import {ConfirmedOwner} from "@chainlink/src/v0.8/shared/access/ConfirmedOwner.sol";
import {FunctionsRequest} from "@chainlink/src/v0.8/functions/dev/v1_0_0/libraries/FunctionsRequest.sol";
import {LinkTokenInterface} from "@chainlink/src/v0.8/shared/interfaces/LinkTokenInterface.sol";
import {IERC1363} from "../lib/openzeppelin-contracts/contracts/interfaces/IERC1363.sol";
import "../lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import "../lib/openzeppelin-contracts/contracts/access/AccessControl.sol";
import "../lib/openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol";
import "./CFPStructs.sol";

// Triggered when an operation is attempted before the contest's timer has expired.
// The 'contestId' parameter is the ID of the contest whose timer has not yet expired.
error TimerHasNotExpired(uint256 contestId);

// Triggered when an attempt is made to score a contest that is not in the 'ready' state.
// The 'contestId' parameter is the ID of the contest that is not in the 'ready' state.
// 'Ready' state in the context of contests means:
// contestStatus = ContestStatus.Verified or contestStatus = ContestStatus.NotMatching
error ScoreContestNotInReadyStatus(uint256 contestId);

// Triggered when a manual scoring attempt is made on a contest that cannot be scored manually.
// The 'contestId' parameter is the ID of the contest that cannot be manually scored.
error ContestUnableToBeScoredManually(uint256 contestId);

// Triggered when the amount of Link tokens provided by the sender is insufficient for the operation.
error LinkAmountTooLowFromSender(uint256 requiredAmount);

// Triggered when the amount of Link tokens provided is insufficient for the operation.
error LinkAmountTooLow(uint256 requiredAmount);

// Triggered when the hash does not match the hash in the constructor (or current) used for contest creation and scoring.
error IncorrectHash();

// Triggered if request ID does not match the expected value
error UnexpectedRequestID(bytes32 requestId);

contract ContestOracleResolved is FunctionsClient, ConfirmedOwner, AccessControl, ReentrancyGuard {
    using FunctionsRequest for FunctionsRequest.Request;

    // Address of the Link token contract, required for handling LINK transactions.
    address internal immutable linkAddress;

    // Address of router
    address public router;

    // DON ID for the Functions DON to which the requests are sent
    bytes32 public donId;

    // Hash of the source code used to create a contest. This is used to verify the correct source code is being used.
    bytes32 public createContestSourceHash;

    // Hash of the source code used to score a contest. This is used to verify the correct source code is being used.
    bytes32 public scoreContestSourceHash;

    // The divisibility factor of the LINK token to handle decimal places in the token.
    uint256 internal constant LINK_DIVISIBILITY = 10 ** 18;

    // The amount to divide LINK by, to pay the subscription fee to the DON
    uint256 public linkDenominator = 4;

    // The latest request id, latest received response, and latest received error (if any) are defined as state variables
    bytes32 public s_lastRequestId;
    bytes public s_lastResponse;
    bytes public s_lastError;

    // Role identifier for a user who has permissions to manually score contests or modify the timer interval.
    bytes32 public constant SCOREMANAGER_ROLE = keccak256("SCOREMANAGER_ROLE");

    // Role identifier for a user who has permissions to change the js source that is executed by the DON.
    bytes32 public constant SOURCEMANAGER_ROLE = keccak256("SOURCEMANAGER_ROLE");

    // Role identifier for a user who has permissions to change subscription fee requirement, withdraw LINK, and update DON address.
    bytes32 public constant SUBSCRIPTIONMANAGER_ROLE = keccak256("SUBSCRIPTIONMANAGER_ROLE");

    // Counter for the contest ids. Each new contest increments this counter.
    uint256 public contestId = 0;

    // The interval that must pass before an attempt at scoring a contest may be made. 
    // This timer prevents excessive scoring attempts.
    uint256 public contestTimerInterval = 4 minutes;

    // Mapping of contest IDs to Contest structs. This stores all the information for each contest.
    mapping(uint256 => Contest) public contests;

    // Mapping of contest IDs to the last time the scoreContest function was called for that contest.
    mapping(uint256 => uint256) public contestTimers;

    // Mapping of contest IDs to the timestamp of when the contest was created.
    // This is used to identify contests that are too old and can be voided.
    mapping(uint256 => uint256) public contestCreationTime;

    // Mapping of request IDs to contest IDs. This allows the correct contest to be updated when an oracle response is received.
    mapping(bytes32 => uint256) public requestMapping;

    // Emitted when OCRResponse has been received. `requestId` is the id of the OCR request, `result` is the OCR result, and `err` contains any potential error messages.
    event Response(bytes32 indexed requestId, bytes response, bytes err);

    // Emitted when a new contest is created.
    // `contestId` is the unique id of the contest, 
    // `rundownId` is the id from rundown API, 
    // `sportspageId` is the id from sportspage API, 
    // `jsonoddsId` is the id from the jsonodds API, 
    // `contestCreator` is the address of the contest creator, and 
    // `contestCriteria` is a uint256 that represents: contest league, teams, and start time
    event ContestCreated(
        uint256 indexed contestId,
        string rundownId,
        string sportspageId,
        string jsonoddsId,
        address contestCreator,
        uint256 contestCriteria // was uint64
    );

    // Emitted when a contest is scored. 
    // `contestId` is the unique id of the contest, 
    // `awayScore` is the score of the away team, and 
    // `homeScore` is the score of the home team.
    event ContestScored(uint256 indexed contestId, uint32 awayScore, uint32 homeScore);

    /**
     * @notice Executes once when a contract is created to initialize state variables
     *
     * @param _router The FunctionsOracle router address
     * @param linkTokenAddress Linktoken contract address
     * @param createContestSourceHashValue JavaScript source hash for contest creation, to prevent people running their own script
     * @param scoreContestSourceHashValue JavaScript source hash for contest scoring, to prevent people running their own script
     */
    constructor(
        address _router, 
        bytes32 _donId,
        address linkTokenAddress, 
        bytes32 createContestSourceHashValue,
        bytes32 scoreContestSourceHashValue
    ) FunctionsClient(_router) ConfirmedOwner(msg.sender) {
        router = _router;
        donId = _donId;
        require(
            linkTokenAddress != address(0),
            "Link token address is not set"
        );
        linkAddress = linkTokenAddress;
        
        // Source hashes may only be altered by the source manager
        createContestSourceHash = createContestSourceHashValue;
        scoreContestSourceHash = scoreContestSourceHashValue;
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
    }

    // Ensures that the hash of the provided 'source' string is equal to the stored 'createContestSourceHash'
    // If not, the function call is reverted with an "Incorrect hash" error message
    modifier correctCreateContestHash(string memory source) {
        if (keccak256(abi.encodePacked(source)) != createContestSourceHash) {
            revert IncorrectHash();
        }
        _;
    }

    // Ensures that the hash of the provided 'source' string is equal to the stored 'scoreContestSourceHash'
    // If not, the function call is reverted with an "Incorrect hash" error message
    modifier correctScoreContestHash(string memory source) {
        if (keccak256(abi.encodePacked(source)) != scoreContestSourceHash) {
            revert IncorrectHash();
        }
        _;
    }

    // Ensures that the 'contestTimer' for a given contest has expired before the function can be called
    // If the timer has not expired, the function call is reverted with a 'TimerHasNotExpired' error
    modifier timerExpired(uint256 _contestId) {
        if (contestTimers[_contestId] + contestTimerInterval >= block.timestamp) {
            revert TimerHasNotExpired(_contestId);
        }
        _;
    }

    // Ensures that the status of the contest is either 'Verified' or 'NotMatching' before the scoring function can be called
    // If the status is not 'Verified' or 'NotMatching', the function call is reverted with a 'ScoreContestNotInReadyStatus' error
    modifier scoreContestReadyStatus(uint256 _contestId) {
        if (
            !(contests[_contestId].contestStatus == ContestStatus.Verified || contests[_contestId].contestStatus == ContestStatus.NotMatching)
        ) {
            revert ScoreContestNotInReadyStatus(_contestId);
        }
        _;
    }

    // Ensures that the subscription fee needed to call the DON is paid for
    // LINK will need to be transferred to the contract and should be done so when creating or scoring a contest
    modifier paySubscriptionFee(uint64 subscriptionId) {
        // Pay the subscription fee with LINK tokens. If the payment fails, revert the transaction with a meaningful error message.
        bool subscriptionPaid = IERC1363(linkAddress).transferAndCall(
            router,
            LINK_DIVISIBILITY / linkDenominator,
            abi.encode(subscriptionId)
        );
        if (!subscriptionPaid) revert LinkAmountTooLow(LINK_DIVISIBILITY / linkDenominator);
        _;
    }

    /**
    * @notice Create a new Contest using ids from three different APIs
    *
    * @param rundownId Contest id from Rundown API
    * @param sportspageId Contest id from Sportspage API
    * @param jsonoddsId Contest id from the JSON Odds API
    * @param source JavaScript source code
    * @param encryptedSecretsUrls The encrypted secrets url
    * @param subscriptionId Funtions billing subscription ID
    * @param gasLimit Maximum amount of gas used to call the client contract's `handleOracleFulfillment` function
    */
    function createContest(
        string memory rundownId,
        string memory sportspageId,
        string memory jsonoddsId,
        string calldata source,
        bytes calldata encryptedSecretsUrls,
        uint64 subscriptionId,
        uint32 gasLimit
    ) external correctCreateContestHash(source) 
        nonReentrant 
        paySubscriptionFee(subscriptionId)
    {
        // Increment the contestId for the new contest
        contestId++;

        // Prepare the args array for the oracle request
        string[] memory args = new string[](3);
        args[0] = rundownId;
        args[1] = sportspageId;
        args[2] = jsonoddsId;

        // Send the oracle request
        sendRequest(source, encryptedSecretsUrls, args, subscriptionId, gasLimit, donId, contestId);

        // Initialize the new contest and store it in the contests mapping
        Contest storage contest = contests[contestId];
        contestTimers[contestId] = block.timestamp;
        contestCreationTime[contestId] = block.timestamp;
        contest.rundownId = rundownId;
        contest.sportspageId = sportspageId;
        contest.jsonoddsId = jsonoddsId;
        contest.awayScore = 0;
        contest.homeScore = 0;
        contest.contestCreator = msg.sender;
    }

    /**
    * @notice Score a Contest using the contest id
    *
    * @param _contestId Contest id to identify the correct contest struct
    * @param source JavaScript source code
    * @param encryptedSecretsUrls The encrypted secrets url
    * @param subscriptionId Funtions billing subscription ID
    * @param gasLimit Maximum amount of gas used to call the client contract's `handleOracleFulfillment` function
    */
    function scoreContest(
        uint256 _contestId,
        string calldata source,
        bytes calldata encryptedSecretsUrls,
        uint64 subscriptionId,
        uint32 gasLimit
    ) external timerExpired(_contestId) 
        scoreContestReadyStatus(_contestId) 
        correctScoreContestHash(source) 
        nonReentrant
        paySubscriptionFee(subscriptionId)
    {
        // Update the contest timer, minimizes the posibility of calling score contest multiple times in too short of an interval
        contestTimers[_contestId] = block.timestamp;

        // Prepare the args array for the oracle request
        {
            string[] memory args = new string[](3);
            args[0] = contests[_contestId].rundownId;
            args[1] = contests[_contestId].sportspageId;
            args[2] = contests[_contestId].jsonoddsId;

            // Send the oracle request
            sendRequest(source, encryptedSecretsUrls, args, subscriptionId, gasLimit, donId, _contestId);
        }
    }

    /**
    * @notice Score contest manually - only possible if contestStatus is NotMatching
    *
    * @param _contestId Contest id to identify the correct contest struct
    * @param awayScore Score of the away team
    * @param homeScore Score of the home team
    */
    function scoreContestManually(
        uint256 _contestId,
        uint32 awayScore,
        uint32 homeScore
    ) external onlyRole(SCOREMANAGER_ROLE) {
        if (
            contests[_contestId].contestStatus != ContestStatus.NotMatching &&
            contests[_contestId].contestStatus != ContestStatus.RequiresConfirmation
        ) {
            revert ContestUnableToBeScoredManually(_contestId);
        }
        Contest storage contestToUpdate = contests[_contestId];
        contestToUpdate.awayScore = awayScore;
        contestToUpdate.homeScore = homeScore;
        contestToUpdate.contestStatus = ContestStatus.ScoredManually;
        emit ContestScored(_contestId, awayScore, homeScore);
    }

    /**
    * @notice Sends a request
    *
    * @param source The source code for the request.
    * @param encryptedSecretsUrls The encrypted secrets url.
    * @param args The arguments accessible from within the source code.
    * @param subscriptionId Functions billing subscription ID.
    * @param gasLimit Maximum amount of gas used to call the client contract's `handleOracleFulfillment` function.
    * @param jobId ID of the job to be invoked
    * @param _contestId The contest id utilized in the callback to update the appropriate contest struct.
    */
    function sendRequest(
        string memory source,
        bytes memory encryptedSecretsUrls,
        string[] memory args,
        uint64 subscriptionId,
        uint32 gasLimit,
        bytes32 jobId,
        uint256 _contestId
    ) internal returns (bytes32 requestId) {
        FunctionsRequest.Request memory req;
        req.initializeRequestForInlineJavaScript(source);
        if (encryptedSecretsUrls.length > 0) {
            req.addSecretsReference(encryptedSecretsUrls);
        }
        if (args.length > 0) req.setArgs(args);
        s_lastRequestId = _sendRequest(
            req.encodeCBOR(),
            subscriptionId,
            gasLimit,
            jobId
        );
        requestMapping[s_lastRequestId] = _contestId;
        return s_lastRequestId;
    }

    /**
    * @notice Callback that is invoked once the DON has resolved the request or hit an error
    *
    * @param requestId The request ID, returned by sendRequest()
    * @param response Aggregated response from the user code
    * @param err Aggregated error from the user code or from the execution pipeline
    * Either response or error parameter will be set, but never both
    */
    function fulfillRequest(bytes32 requestId, bytes memory response, bytes memory err) internal override {
        if (s_lastRequestId != requestId) {
            revert UnexpectedRequestID(requestId);
        }
        s_lastResponse = response;
        s_lastError = err;
        emit Response(requestId, s_lastResponse, s_lastError);

        // requestId is used to identify the propert contest struct to update
        Contest storage contestToUpdate = contests[requestMapping[requestId]];

        // If there are no errors and the contest status is unverified, this result is used to verify a valid contest (based on IDs from the APIs)
        if (err.length == 0 && contestToUpdate.contestStatus == ContestStatus.Unverified) {
            contestToUpdate.contestStatus = ContestStatus.Verified;
            emit ContestCreated(
                requestMapping[requestId],
                contestToUpdate.rundownId,
                contestToUpdate.sportspageId,
                contestToUpdate.jsonoddsId,
                contestToUpdate.contestCreator,
                uint256(bytes32(response))
            );
        } 

        // If there are no errors and the contest status is verified, this result is used to update the scores of the contest
        else if (err.length == 0 && contestToUpdate.contestStatus == ContestStatus.Verified) {
            uint32[2] memory contestScore = uintToResultScore(bytesToUint32(response));
            contestToUpdate.awayScore = contestScore[0];
            contestToUpdate.homeScore = contestScore[1];

            // if the score return from oracle network results in a 0-0 contest final, this must be confirmed
            if (contestToUpdate.awayScore + contestToUpdate.homeScore == 0) {
                contestToUpdate.contestStatus = ContestStatus.RequiresConfirmation;
            } else {
                contestToUpdate.contestStatus = ContestStatus.Scored;
                emit ContestScored(
                    requestMapping[requestId],
                    contestToUpdate.awayScore,
                    contestToUpdate.homeScore
                );
            }
        }
    }

    /**
    * @notice Get contest is utilized by the interface to return a contest struct
    *
    * @param _contestId Contest id to identify the correct contest struct
    */
    function getContest(uint256 _contestId) public view returns (Contest memory) {
        return contests[_contestId];
    }

    /**
    * @notice updateTimer function utilized to update the timer interval
    *
    * @param newContestTimerInterval The new timer interval
    */
    function updateTimer(
        uint256 newContestTimerInterval
    ) external onlyRole(SCOREMANAGER_ROLE) {
        contestTimerInterval = newContestTimerInterval;
    }

    /**
    * @notice Set the DON ID
    * @param newDonId New DON ID
    */
    function setDonId(bytes32 newDonId) external onlyRole(SUBSCRIPTIONMANAGER_ROLE) {
        donId = newDonId;
    }

    /**
    * @notice Allows the router address to be updated
    *
    * @param _router New router address
    */
    function updateRouterAddress(address _router) external onlyRole(SUBSCRIPTIONMANAGER_ROLE) {
        router = _router;
    }

    /**
    * @notice updateLinkDenominator function utilized to update the LINK denominator amount
    * default is 4, so 0.25 LINK required to call functions requiring a DON subscription
    * changing this value to 2 would change LINK required to 0.5, a value of 8 changes LINK required to 0.125, etc.
    *
    * @param newLinkDenominator The new LINK denominator value
    */
    function updateLinkDenominator(
        uint256 newLinkDenominator
    ) external onlyRole(SUBSCRIPTIONMANAGER_ROLE) {
        linkDenominator = newLinkDenominator;
    }

    /**
    * @notice withdrawAllLink function utilized to withdraw excess LINK from contract
    * 
    * @param to Address to withdraw LINK to
    */
    function withdrawAllLink(
        address to
    ) external onlyRole(SUBSCRIPTIONMANAGER_ROLE) {
        IERC20 linkToken = IERC20(linkAddress);
        uint256 contractBalance = linkToken.balanceOf(address(this));
        require(contractBalance > 0, "No tokens to withdraw");
        linkToken.transfer(to, contractBalance);
    }

    /**
    * @notice updateSourceHash function utilized to update source hashes for creating and scoring contests
    *
    * @param sourceHashToUpdate The source hash that is being updated
    * @param newSourceHash The new source hash to use (replaces the original hash)
    */
    function updateSourceHash(
        bytes32 sourceHashToUpdate,
        bytes32 newSourceHash
    ) external onlyRole(SOURCEMANAGER_ROLE) {
        if (sourceHashToUpdate == createContestSourceHash) {
            createContestSourceHash = newSourceHash;
        } else 
        if (sourceHashToUpdate == scoreContestSourceHash) {
            scoreContestSourceHash = newSourceHash;
        }
    }

    /**
    * @notice Converts bytes response from the DON to a uint32
    *
    * @param input The bytes response from the DON, this conversion takes place prior to converting the score
    */
    function bytesToUint32(bytes memory input) public pure returns (uint32 output) {
        require(input.length >= 4, "Input string must have at least 4 bytes");
        
        // use inline assembly for byte shifting
        assembly {
            output := mload(add(input, 32))
        }
    }

    /**
    * @notice Converts uint response from the DON to contest score
    *
    * @param _uint The uint response from the DON that will contain both the away and home team's score
    */
    function uintToResultScore(
        uint32 _uint
    ) internal pure returns (uint32[2] memory) {
        uint32[2] memory scoreArr;
        scoreArr[1] = _uint % 1000;
        scoreArr[0] = (_uint - scoreArr[1]) / 1000;
        return scoreArr;
    }
}
