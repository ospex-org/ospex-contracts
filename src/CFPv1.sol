// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "./CFPStructs.sol";

interface ISpeculationScorer {
    function determineWinSide(
        uint256 _id,
        int32 _theNumber
    ) external view returns (WinSide);
}

error SpeculationHasStarted(uint256 speculationId);
error SpeculationAmountNotAboveMinimum(uint256 amountSpeculated);
error SpeculationAmountIsAboveMaximum(uint256 amountSpeculated);
error ContributionMayNotExceedTotalAmount(
    uint256 amountSpeculated,
    uint256 contributionAmount
);
error TimerHasNotExpired(uint256 speculationId);
error SpeculationStatusIsClosed(uint256 speculationId);
error SpeculationStatusIsNotClosed(uint256 speculationId);
error WinningsAlreadyClaimed(uint256 positionId);
error IneligibleForWinnings(uint256 positionId);
error SpeculationMayNotBeVoided(uint256 speculationId);
error SpeculationMayNotBeForfeited(uint256 speculationId);

contract CFPv1 is AccessControl, ReentrancyGuard {
    // where contributions go
    address public DAOAddress;

    // token is USDC
    IERC20 public usdc;

    // create role for OpenZeppelin defender relayer
    bytes32 public constant RELAYER_ROLE = keccak256("RELAYER_ROLE");
    // create role for manager of score logic address
    bytes32 public constant SCOREMANAGER_ROLE = keccak256("SCOREMANAGER_ROLE");

    uint256 public minSpeculationAmount = 1 * 10 ** 18; // 10**18 on Goerli, will need to be 10**6 in production
    uint256 public maxSpeculationAmount = 10 * 10 ** 18; // remove once contract is audited, 10**18 on Goerli, will need to be 10**6 in production
    uint256 public voidTime = 3 days;
    uint256 public speculationTimerInterval = 4 minutes;

    // id to be incremented as new instances are added
    uint256 public speculationId = 1;

    // reference id for speculation struct
    mapping(uint256 => Speculation) public speculations;
    // example: positions[id][address] where id = speculationId and address = userAddress
    // positions[id] returns all the addresses with a position on a particular speculationId
    mapping(uint256 => mapping(address => Position)) public positions;
    // mapping to speculation types and addresses
    mapping(address => ISpeculationScorer) public speculationTypes;
    // timer for calling score speculation function
    mapping(uint256 => uint256) public speculationTimers;

    event SpeculationCreated(
        uint256 indexed id,
        uint256 indexed contestId,
        uint32 lockTime,
        address speculationScorer,
        int32 theNumber,
        address speculationCreator
    );
    event SpeculationLocked(uint256 indexed id, uint256 indexed contestId);
    event SpeculationScored(
        uint256 indexed id,
        uint256 indexed contestId,
        uint256 upperAmount,
        uint256 lowerAmount,
        WinSide winSide
    );
    event PositionCreated(
        uint256 indexed id,
        address indexed user,
        uint256 amount,
        uint256 contributionAmount,
        PositionType positionType
    );
    event Claim(
        address indexed user,
        uint256 indexed id,
        uint256 amount,
        uint256 contributionAmount
    );
    event SpeculationTypeAdded(
        address indexed speculationScorer,
        string description
    );

    constructor(
        address _DAOAddress,
        IERC20 _usdc,
        address _speculationSpreadScorer,
        address _speculationTotalScorer,
        address _speculationMoneylineScorer
    ) {
        _setupRole(DEFAULT_ADMIN_ROLE, msg.sender);
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
    }

    // contest status must be open...not locked (contest in progress) and not closed (contest completed)
    modifier speculationStatusIsOpen(uint256 _id) {
        if (!_speculationStatusOpen(_id)) {
            revert SpeculationHasStarted(_id);
        }
        _;
    }

    // amount speculated must be above the minimum accepted (1 USDC)
    modifier speculationAmountIsAboveMinimum(uint256 _amount) {
        if (_amount < minSpeculationAmount) {
            revert SpeculationAmountNotAboveMinimum(_amount);
        }
        _;
    }

    modifier speculationAmountIsBelowMaximum(uint256 _amount) {
        if (_amount > maxSpeculationAmount) {
            revert SpeculationAmountIsAboveMaximum(_amount);
        }
        _;
    }

    // contest locktime must be less than the current blocktime - this is a fallback in case something goes wrong with speculationStatusIsOpen
    modifier speculationHasNotStarted(uint256 _id) {
        if (speculations[_id].lockTime <= block.timestamp) {
            revert SpeculationHasStarted(_id);
        }
        _;
    }

    modifier contributionExceedsAmount(
        uint256 _amount,
        uint256 _contributionAmount
    ) {
        if (_amount < _contributionAmount) {
            revert ContributionMayNotExceedTotalAmount(
                _amount,
                _contributionAmount
            );
        }
        _;
    }

    // scoreContest can only be called if the current time is [contestTimer] greater than the last time the function was called
    modifier timerExpired(uint256 _id) {
        if (
            speculationTimers[_id] + speculationTimerInterval >= block.timestamp
        ) {
            revert TimerHasNotExpired(_id);
        }
        _;
    }

    function scoreSpeculation(uint256 _id) external timerExpired(_id) {
        if (speculations[_id].speculationStatus == SpeculationStatus.Closed) {
            revert SpeculationStatusIsClosed(_id);
        }
        speculationTimers[_id] = block.timestamp;
        Speculation storage speculationToUpdate = speculations[_id];
        speculationToUpdate.winSide = speculationTypes[
            speculationToUpdate.speculationScorer
        ].determineWinSide(
                speculationToUpdate.contestId,
                speculationToUpdate.theNumber
            );
        speculationToUpdate.speculationStatus = SpeculationStatus.Closed;
        emit SpeculationScored(
            _id,
            speculationToUpdate.contestId,
            speculationToUpdate.upperAmount,
            speculationToUpdate.lowerAmount,
            speculationToUpdate.winSide
        );
    }

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
        contributionExceedsAmount(_speculationAmount, _contributionAmount)
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

    function claim(
        uint256 _id,
        uint256 _contributionAmount
    ) external nonReentrant {
        if (!_speculationStatusClosed(_id)) {
            revert SpeculationStatusIsNotClosed(_id);
        }
        if (positions[_id][msg.sender].claimed) {
            revert WinningsAlreadyClaimed(_id);
        }
        if (!claimable(_id, msg.sender)) {
            revert IneligibleForWinnings(_id);
        }

        Position storage position = positions[_id][msg.sender];
        position.claimed = true;
        Speculation memory speculationToUpdate = speculations[_id];
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
        if (winnings >= _contributionAmount) {
            usdc.transfer(msg.sender, winnings - _contributionAmount);
            usdc.transfer(DAOAddress, _contributionAmount);
            emit Claim(msg.sender, _id, winnings, _contributionAmount);
        } else {
            usdc.transfer(DAOAddress, winnings);
            emit Claim(msg.sender, _id, 0, winnings);
        }
    }

    function _speculationStatusOpen(uint256 _id) internal view returns (bool) {
        return speculations[_id].speculationStatus == SpeculationStatus.Open;
    }

    function _speculationStatusLocked(
        uint256 _id
    ) internal view returns (bool) {
        return speculations[_id].speculationStatus == SpeculationStatus.Locked;
    }

    function _speculationStatusClosed(
        uint256 _id
    ) internal view returns (bool) {
        return speculations[_id].speculationStatus == SpeculationStatus.Closed;
    }

    function claimable(uint256 _id, address user) internal view returns (bool) {
        Position memory position = positions[_id][user];
        Speculation memory speculation = speculations[_id];
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

    // lock speculation via defender autotask once it has begun
    function lockSpeculation(uint256 _id) external onlyRole(RELAYER_ROLE) {
        Speculation storage speculationToUpdate = speculations[_id];

        // if all the positions are on one side, close the speculation and score it invalid
        if (
            speculationToUpdate.upperAmount == 0 ||
            speculationToUpdate.lowerAmount == 0
        ) {
            speculationToUpdate.speculationStatus = SpeculationStatus.Closed;
            speculationToUpdate.winSide = WinSide.Invalid;
            emit SpeculationLocked(_id, speculationToUpdate.contestId);
            emit SpeculationScored(
                _id,
                speculationToUpdate.contestId,
                speculationToUpdate.upperAmount,
                speculationToUpdate.lowerAmount,
                speculationToUpdate.winSide
            );
        } else {
            speculationToUpdate.speculationStatus = SpeculationStatus.Locked;
            emit SpeculationLocked(_id, speculationToUpdate.contestId);
        }
    }

    // close speculation in the event of a postponement (can only forfeit when status is open)
    function forfeitSpeculation(
        uint256 _id
    ) external onlyRole(SCOREMANAGER_ROLE) {
        if (!(_speculationStatusOpen(_id))) {
            revert SpeculationMayNotBeForfeited(_id);
        }
        Speculation storage speculationToUpdate = speculations[_id];
        speculationToUpdate.speculationStatus = SpeculationStatus.Closed;
        speculationToUpdate.winSide = WinSide.Forfeit;
        emit SpeculationScored(
            _id,
            speculationToUpdate.contestId,
            speculationToUpdate.upperAmount,
            speculationToUpdate.lowerAmount,
            speculationToUpdate.winSide
        );
    }

    // void speculation in the event that void time has passed and there is no resolution, must be initiated by user
    function voidSpeculation(uint256 _id) external {
        if (!_speculationStatusLocked(_id)) {
            revert SpeculationMayNotBeVoided(_id);
        }
        if (speculations[_id].lockTime + voidTime > block.timestamp) {
            revert SpeculationMayNotBeVoided(_id);
        }
        Speculation storage speculationToUpdate = speculations[_id];
        speculationToUpdate.speculationStatus = SpeculationStatus.Closed;
        speculationToUpdate.winSide = WinSide.Void;
    }

    function changeMaxSpeculationAmount(
        uint256 _newMax
    ) external onlyRole(SCOREMANAGER_ROLE) {
        maxSpeculationAmount = _newMax * 10 ** 18; // 10**18 on Goerli, will need to be 10**6 in production
    }

    function changeVoidTime(
        uint256 _newVoidTime
    ) external onlyRole(SCOREMANAGER_ROLE) {
        voidTime = _newVoidTime;
    }

    // add a new address for a new speculation interface
    function addSpeculationType(
        address _speculationScorer,
        string memory _description
    ) external onlyRole(SCOREMANAGER_ROLE) {
        speculationTypes[_speculationScorer] = ISpeculationScorer(
            _speculationScorer
        );
        emit SpeculationTypeAdded(_speculationScorer, _description);
    }

    function updateDAOAddress(
        address _DAOAddress
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        DAOAddress = _DAOAddress;
    }
}
