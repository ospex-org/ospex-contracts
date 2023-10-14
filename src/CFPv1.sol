// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "../lib/openzeppelin-contracts/contracts/access/AccessControl.sol";
import "../lib/openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol";
import "../lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import "./CFPStructs.sol";

interface ISpeculationScorer {
    function determineWinSide(
        uint256 _contestId,
        int32 _theNumber
    ) external view returns (WinSide);
}

// Cannot create a position on a speculation unless the speculation is in the proper status
error SpeculationHasStarted(uint256 speculationId);

// All positions must be between minimum and maximum amount as specified in contract
error SpeculationAmountNotAboveMinimum(uint256 amountSpeculated);
error SpeculationAmountIsAboveMaximum(uint256 amountSpeculated);

// Attempting to contribute a higher amount than is being used to create a position will result in an error
error ContributionMayNotExceedTotalAmount(
    uint256 amountSpeculated,
    uint256 contributionAmount
);

// Speculation timer must expire before attempting to finalize the score of a speculation
error TimerHasNotExpired(uint256 speculationId);

// Attempting to score a speculation that is already closed will result in an error
error SpeculationStatusIsClosed(uint256 speculationId);

// Attempting to execute a claim on a position where the speculation is not closed will result in an error
error SpeculationStatusIsNotClosed(uint256 speculationId);

// Attempting to claim on a position more than once will result in an error
error WinningsAlreadyClaimed(uint256 speculationId);

// Attempting to claim on a position that is not claimable will result in an error
error IneligibleForWinnings(uint256 speculationId);

// Speculations may only be voided if they are locked and void time has passed; if not, an error will occur
error SpeculationMayNotBeVoided(uint256 speculationId);

// Speculations that are not in open status may not be forfeited
error SpeculationMayNotBeForfeited(uint256 speculationId);

contract CFPv1 is AccessControl, ReentrancyGuard {
    
    // Contributions are transferred to the address below
    address public DAOAddress;

    // Token is USDC
    IERC20 public usdc;

    // Role for OpenZeppelin Defender Relayer; Relayer used to move speculations to locked status
    // If Relayer fails to lock speculation, block timestamp should still prevent positions from being created after contest has begun
    // Speculations can skip lock status; this originated as an additional check against using only block timestamp to prevent speculating after contest start
    bytes32 public constant RELAYER_ROLE = keccak256("RELAYER_ROLE");

    // Create role for manager of various tasks on contract, including: forfeiting speculations (provided they are not locked),
    // changing maximum speculation amount and void time, and adding new speculation types (experimental feature, may not be used)
    bytes32 public constant SCOREMANAGER_ROLE = keccak256("SCOREMANAGER_ROLE");

    // Speculation amounts must be between the following amounts
    uint256 public minSpeculationAmount = 1 * 10 ** 6;
    uint256 public maxSpeculationAmount = 10 * 10 ** 6;

    // Void time is used to determine how long before a speculation may be moved to void status, which allows for all speculators to 
    // claim their original speculated amount; this would be used if a contest is canceled or voided
    uint256 public voidTime = 3 days;

    // Anyone can initiate the scoring of a speculation, provided the timer interval has passed
    uint256 public speculationTimerInterval = 4 minutes;

    // Id to be incremented as new speculations are added
    uint256 public speculationId = 1;

    // Reference id for speculation struct
    mapping(uint256 => Speculation) public speculations;

    // Example: positions[id][address] where id = speculationId and address = userAddress
    // positions[id] returns all the addresses with a position on a particular speculationId
    mapping(uint256 => mapping(address => Position)) public positions;

    // Mapping to speculation types and addresses for scoring each type
    mapping(address => ISpeculationScorer) public speculationTypes;

    // Timer for calling score speculation function
    mapping(uint256 => uint256) public speculationTimers;

    // Emitted when a new speculation is created
    // `speculationId` is the unique id of the speculation,
    // `contestId` is the unique id of the contest,
    // `lockTime` is the time in which the speculation should begin (no speculations after this time),
    // `speculationScorer` is the address of the interface that should be used to score the speculation,
    // `theNumber` is the number used to determine scoring within the interface (if applicable),
    // `speculationCreator` is the address of the user that created the speculation, as anyone can create them
    event SpeculationCreated(
        uint256 indexed speculationId,
        uint256 indexed contestId,
        uint32 lockTime,
        address speculationScorer,
        int32 theNumber,
        address speculationCreator
    );

    // Emitted when the speculation is locked by the Relayer
    // `speculationId` is the unique id of the speculation,
    // `contestId` is the unique id of the contest,
    event SpeculationLocked(uint256 indexed speculationId, uint256 indexed contestId);

    // Emitted when the speculation is scored
    // `speculationId` is the unique id of the speculation,
    // `contestId` is the unique id of the contest,
    // `upperAmount` is the first score returned by the DON and represents the away team total
    // `lowerAmount` is the second score returned by the DON and represents the home team total
    // `winSide` represents the winning side of the speculation, see enum for these options
    event SpeculationScored(
        uint256 indexed speculationId,
        uint256 indexed contestId,
        uint256 upperAmount,
        uint256 lowerAmount,
        WinSide winSide
    );

    // Emitted when a position is created
    // `speculationId` is the unique id of the speculation,
    // `user` is the address that created the position,
    // `amount` is the amount that was used to create the position,
    // `contributionAmount` is the amount passed to the DAO address at the time of position creation,
    // `positionType` is the type of position, see enum for these options
    event PositionCreated(
        uint256 indexed speculationId,
        address indexed user,
        uint256 amount,
        uint256 contributionAmount,
        PositionType positionType
    );

    // Emitted when a claim is made
    // `user` is the address that initiated the claim,
    // `speculationId` is the unique id of the speculation,
    // `amount` is the amount that is being claimed
    // `contributionAmount` is the amount passed to the DAO address at the time of claim
    event Claim(
        address indexed user,
        uint256 indexed speculationId,
        uint256 amount,
        uint256 contributionAmount
    );

    // Emitted when a new speculation type has been added to the contract (experimental)
    // It is unknown whether new speculation types will be added, however it is possible to add them
    // `speculationScorer` is the address that will be used as an interface to score this speculation
    // `description` is a description of this type of speculation
    event SpeculationTypeAdded(
        address indexed speculationScorer,
        string description
    );

    /**
     * @notice Executes once when a contract is created to initialize state variables
     *
     * @param _DAOAddress Contribution address
     * @param _usdc USDC token address
     * @param _speculationSpreadScorer Interface address for scoring speculations based on contest spread
     * @param _speculationTotalScorer Interface address for scoring speculations based on contest total
     * @param _speculationMoneylineScorer Interface address for scoring speculations based on contest winner (moneyline)
     */
    constructor(
        address _DAOAddress,
        IERC20 _usdc,
        address _speculationSpreadScorer,
        address _speculationTotalScorer,
        address _speculationMoneylineScorer
    ) {
        DAOAddress = _DAOAddress;
        usdc = _usdc;
        speculationTypes[_speculationSpreadScorer] = ISpeculationScorer(
            _speculationSpreadScorer
        );
        speculationTypes[_speculationTotalScorer] = ISpeculationScorer(
            _speculationTotalScorer
        );
        speculationTypes[_speculationMoneylineScorer] = ISpeculationScorer(
            _speculationMoneylineScorer
        );
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
    }

    // Ensures contest status is open...not locked (contest in progress) and not closed (contest completed)
    modifier speculationStatusIsOpen(uint256 _speculationId) {
        if (!_speculationStatusOpen(_speculationId)) {
            revert SpeculationHasStarted(_speculationId);
        }
        _;
    }

    // Amount speculated must be above the minimum accepted (1 USDC)
    modifier speculationAmountIsAboveMinimum(uint256 _amount) {
        if (_amount < minSpeculationAmount) {
            revert SpeculationAmountNotAboveMinimum(_amount);
        }
        _;
    }

    // Amount speculated must be below the maximum accepted (10 USDC to start, SCOREMANAGER_ROLE can change)
    modifier speculationAmountIsBelowMaximum(uint256 _amount) {
        if (_amount > maxSpeculationAmount) {
            revert SpeculationAmountIsAboveMaximum(_amount);
        }
        _;
    }

    // Speculation locktime must be less than the current blocktime
    modifier speculationHasNotStarted(uint256 _speculationId) {
        if (speculations[_speculationId].lockTime <= block.timestamp) {
            revert SpeculationHasStarted(_speculationId);
        }
        _;
    }

    // scoreContest can only be called if the current time is [contestTimer] greater than the last time the function was called
    modifier timerExpired(uint256 _speculationId) {
        if (
            speculationTimers[_speculationId] + speculationTimerInterval >= block.timestamp
        ) {
            revert TimerHasNotExpired(_speculationId);
        }
        _;
    }

    /**
    * @notice Score a speculation; should work provided speculation is not closed, timer has expired and contest has a score
    *
    * @param _speculationId Speculation id to identify the correct speculation struct
    */
    function scoreSpeculation(uint256 _speculationId) external timerExpired(_speculationId) {
        if (speculations[_speculationId].speculationStatus == SpeculationStatus.Closed) {
            revert SpeculationStatusIsClosed(_speculationId);
        }
        speculationTimers[_speculationId] = block.timestamp;
        Speculation storage speculationToUpdate = speculations[_speculationId];
        speculationToUpdate.winSide = speculationTypes[
            speculationToUpdate.speculationScorer
        ].determineWinSide(
                speculationToUpdate.contestId,
                speculationToUpdate.theNumber
            );
        speculationToUpdate.speculationStatus = SpeculationStatus.Closed;
        emit SpeculationScored(
            _speculationId,
            speculationToUpdate.contestId,
            speculationToUpdate.upperAmount,
            speculationToUpdate.lowerAmount,
            speculationToUpdate.winSide
        );
    }

    /**
    * @notice Create a position, for a user on a speculation
    *
    * @param _speculationId Speculation id to identify the correct speculation struct
    * @param _speculationAmount Amount used to create the position
    * @param _contributionAmount Amount to pass to the DAO address
    * @param _positionType Type of position, either upper (away side / over) or lower (home side / under)
    */
    function createPosition(
        uint256 _speculationId,
        uint256 _speculationAmount,
        uint256 _contributionAmount,
        PositionType _positionType
    )
        external
        speculationStatusIsOpen(_speculationId)
        speculationAmountIsAboveMinimum(_speculationAmount)
        speculationAmountIsBelowMaximum(_speculationAmount)
        speculationHasNotStarted(_speculationId)
        nonReentrant
    {
        usdc.transferFrom(msg.sender, address(this), _speculationAmount);
        usdc.transferFrom(msg.sender, DAOAddress, _contributionAmount);
        Position storage positionToUpdate = positions[_speculationId][
            msg.sender
        ];
        Speculation storage speculationToUpdate = speculations[_speculationId];

        if (_positionType == PositionType.Upper) {
            positionToUpdate.upperAmount += _speculationAmount;
            speculationToUpdate.upperAmount += _speculationAmount;
        } else if (_positionType == PositionType.Lower) {
            positionToUpdate.lowerAmount += _speculationAmount;
            speculationToUpdate.lowerAmount += _speculationAmount;
        }

        emit PositionCreated(
            _speculationId,
            msg.sender,
            _speculationAmount,
            _contributionAmount,
            _positionType
        );
    }

    /**
    * @notice Initiate a claim of a winning position
    *
    * @param _speculationId Speculation id to identify the correct speculation struct
    * @param _contributionAmount Amount to pass to the DAO address
    */
    function claim(
        uint256 _speculationId,
        uint256 _contributionAmount
    ) external nonReentrant {
        if (!_speculationStatusClosed(_speculationId)) {
            revert SpeculationStatusIsNotClosed(_speculationId);
        }
        if (positions[_speculationId][msg.sender].claimed) {
            revert WinningsAlreadyClaimed(_speculationId);
        }
        if (!claimable(_speculationId, msg.sender)) {
            revert IneligibleForWinnings(_speculationId);
        }

        Position storage position = positions[_speculationId][msg.sender];
        position.claimed = true;
        Speculation memory speculationToUpdate = speculations[_speculationId];
        uint256 winnings;
        uint256 totalAmount = speculationToUpdate.upperAmount +
            speculationToUpdate.lowerAmount;

        if (
            speculationToUpdate.winSide == WinSide.Away ||
            speculationToUpdate.winSide == WinSide.Over
        ) {
            winnings =
                (position.upperAmount * totalAmount) /
                speculationToUpdate.upperAmount;
        } else if (
            speculationToUpdate.winSide == WinSide.Home ||
            speculationToUpdate.winSide == WinSide.Under
        ) {
            winnings =
                (position.lowerAmount * totalAmount) /
                speculationToUpdate.lowerAmount;
        } else {
            winnings = (position.upperAmount + position.lowerAmount);
        }

        // if winnings exceed contribution amount, subtract contribution from winnings and send each value to the appropriate place
        // else send 100% of winnings to contribution address
        if (winnings > _contributionAmount) {
            usdc.transfer(msg.sender, winnings - _contributionAmount);
            usdc.transfer(DAOAddress, _contributionAmount);
            emit Claim(msg.sender, _speculationId, winnings, _contributionAmount);
        } else {
            usdc.transfer(DAOAddress, winnings);
            emit Claim(msg.sender, _speculationId, 0, winnings);
        }
    }

    /**
    * @notice Determine if speculation status is open, returns boolean
    *
    * @param _speculationId Speculation id to identify the correct speculation struct
    */
    function _speculationStatusOpen(uint256 _speculationId) internal view returns (bool) {
        return speculations[_speculationId].speculationStatus == SpeculationStatus.Open;
    }

    /**
    * @notice Determine if speculation status is locked, returns boolean
    *
    * @param _speculationId Speculation id to identify the correct speculation struct
    */
    function _speculationStatusLocked(
        uint256 _speculationId
    ) internal view returns (bool) {
        return speculations[_speculationId].speculationStatus == SpeculationStatus.Locked;
    }

    /**
    * @notice Determine if speculation status is closed, returns boolean
    *
    * @param _speculationId Speculation id to identify the correct speculation struct
    */
    function _speculationStatusClosed(
        uint256 _speculationId
    ) internal view returns (bool) {
        return speculations[_speculationId].speculationStatus == SpeculationStatus.Closed;
    }

    /**
    * @notice Determine if position is claimable, returns boolean
    *
    * @param _speculationId Speculation id to identify the correct speculation struct
    * @param user User address of position owner
    */
    function claimable(uint256 _speculationId, address user) internal view returns (bool) {
        Position memory position = positions[_speculationId][user];
        Speculation memory speculation = speculations[_speculationId];
        return
            ((speculation.winSide == WinSide.Away &&
                position.upperAmount > 0) ||
                (speculation.winSide == WinSide.Home &&
                    position.lowerAmount > 0) ||
                (speculation.winSide == WinSide.Over &&
                    position.upperAmount > 0) ||
                (speculation.winSide == WinSide.Under &&
                    position.lowerAmount > 0) ||
                (speculation.winSide == WinSide.Push) ||
                (speculation.winSide == WinSide.Forfeit) ||
                (speculation.winSide == WinSide.Invalid)) ||
            (speculation.winSide == WinSide.Void);
    }

    /**
    * @notice Create a new speculation, based on a contest
    *
    * @param _contestId Contest id that the speculation is based on the outcome of
    * @param _lockTime Speculation locktime; after this time, no new positions are allowed
    * @param _speculationScorer Interface address to be used to score the speculation
    * @param _theNumber The number used to determine scoring within the interface (if applicable)
    */
    function createSpeculation(
        uint256 _contestId,
        uint32 _lockTime,
        address _speculationScorer,
        int32 _theNumber
    ) external {
        Speculation storage speculation = speculations[speculationId];
        speculationTimers[speculationId] = _lockTime; // initiated timer value upon speculation creation
        speculation.contestId = _contestId;
        speculation.upperAmount = 0;
        speculation.lowerAmount = 0;
        speculation.lockTime = _lockTime;
        speculation.speculationScorer = _speculationScorer;
        speculation.theNumber = _theNumber;
        speculation.speculationCreator = msg.sender;
        speculation.speculationStatus = SpeculationStatus.Open;
        speculation.winSide = WinSide.TBD;
        emit SpeculationCreated(
            speculationId,
            speculation.contestId,
            speculation.lockTime,
            speculation.speculationScorer,
            speculation.theNumber,
            speculation.speculationCreator
        );
        speculationId++;
    }

    /**
    * @notice Locks speculation via defender autotask once it has begun
    *
    * @param _speculationId Speculation id to identify the correct speculation struct
    */
    function lockSpeculation(uint256 _speculationId) external onlyRole(RELAYER_ROLE) {
        Speculation storage speculationToUpdate = speculations[_speculationId];

        // if all the positions are on one side, close the speculation and score it invalid
        if (
            speculationToUpdate.upperAmount == 0 ||
            speculationToUpdate.lowerAmount == 0
        ) {
            speculationToUpdate.speculationStatus = SpeculationStatus.Closed;
            speculationToUpdate.winSide = WinSide.Invalid;
            emit SpeculationLocked(_speculationId, speculationToUpdate.contestId);
            emit SpeculationScored(
                _speculationId,
                speculationToUpdate.contestId,
                speculationToUpdate.upperAmount,
                speculationToUpdate.lowerAmount,
                speculationToUpdate.winSide
            );
        } else {
            speculationToUpdate.speculationStatus = SpeculationStatus.Locked;
            emit SpeculationLocked(_speculationId, speculationToUpdate.contestId);
        }
    }

    /**
    * @notice Close speculation in the event of a postponement (can only forfeit when status is open)
    *
    * @param _speculationId Speculation id to identify the correct speculation struct
    */
    function forfeitSpeculation(
        uint256 _speculationId
    ) external onlyRole(SCOREMANAGER_ROLE) {
        if (!(_speculationStatusOpen(_speculationId))) {
            revert SpeculationMayNotBeForfeited(_speculationId);
        }
        Speculation storage speculationToUpdate = speculations[_speculationId];
        speculationToUpdate.speculationStatus = SpeculationStatus.Closed;
        speculationToUpdate.winSide = WinSide.Forfeit;
        emit SpeculationScored(
            _speculationId,
            speculationToUpdate.contestId,
            speculationToUpdate.upperAmount,
            speculationToUpdate.lowerAmount,
            speculationToUpdate.winSide
        );
    }

    /**
    * @notice Void speculation in the event that void time has passed and there is no resolution, must be initiated by user
    *
    * @param _speculationId Speculation id to identify the correct speculation struct
    */
    function voidSpeculation(uint256 _speculationId) external {
        if (!_speculationStatusLocked(_speculationId) || ((speculations[_speculationId].lockTime + voidTime) > block.timestamp)) {
            revert SpeculationMayNotBeVoided(_speculationId);
        }
        Speculation storage speculationToUpdate = speculations[_speculationId];
        speculationToUpdate.speculationStatus = SpeculationStatus.Closed;
        speculationToUpdate.winSide = WinSide.Void;
    }

    /**
    * @notice Change maximum allowable speculation amount
    *
    * @param _newMax New maximum allowable speculation amount
    */
    function changeMaxSpeculationAmount(
        uint256 _newMax
    ) external onlyRole(SCOREMANAGER_ROLE) {
        maxSpeculationAmount = _newMax * 10 ** 6;
    }

    /**
    * @notice Change void time
    *
    * @param _newVoidTime New time necessary to void speculation
    */
    function changeVoidTime(
        uint256 _newVoidTime
    ) external onlyRole(SCOREMANAGER_ROLE) {
        voidTime = _newVoidTime;
    }

    /**
    * @notice Add a new speculation type (experimental)
    *
    * @param _speculationScorer New address for a new speculation interface
    * @param _description Description of this type of speculation
    */
    function addSpeculationType(
        address _speculationScorer,
        string memory _description
    ) external onlyRole(SCOREMANAGER_ROLE) {
        speculationTypes[_speculationScorer] = ISpeculationScorer(
            _speculationScorer
        );
        emit SpeculationTypeAdded(_speculationScorer, _description);
    }

    /**
    * @notice Update DAO address
    *
    * @param _DAOAddress Change/update DAO address
    */
    function updateDAOAddress(
        address _DAOAddress
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        DAOAddress = _DAOAddress;
    }
}
