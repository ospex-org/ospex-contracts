// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

/**
 * @title CFPStructs
 * @author ospex.org
 * @notice This contract is part of the ospex dApp, deployed on Polygon Mainnet.
 * @notice alt url: ospex.crypto
 * @dev For more information, visit ospex.org or the project repository at github.com/ospex-org
 * 
 */

struct Contest {
    uint32 awayScore; // final awayScore
    uint32 homeScore; // final homeScore
    address contestCreator;
    ContestStatus contestStatus; // is contest final (and is score available to speculations)
    string rundownId; // from rundown api
    string sportspageId; // from sportspage api
    string jsonoddsId; // from the jsonodds api
}

enum ContestStatus {
    Unverified,
    Verified,
    Scored,
    NotMatching,
    ScoredManually,
    RequiresConfirmation, // for 0-0 oracle-confirmed scores
    Void // untested
}

// contest speculation definition: represents the speculative structure created off of contests
struct Speculation {
    uint256 contestId; // the contest id that this speculation relates to
    uint256 upperAmount; // amount speculated on away side or the over
    uint256 lowerAmount; // amount speculated on home side or the under
    uint32 lockTime; // contest start time, contest is locked and no longer accepting speculations
    address speculationScorer; // contest speculation type is determined from this address
    int32 theNumber; // number that the speculation may be based on
    address speculationCreator;
    SpeculationStatus speculationStatus; // state of contract
    WinSide winSide; // winning side of contest
}

enum SpeculationStatus {
    Open,
    Locked,
    Closed
}
enum WinSide {
    TBD,
    Away,
    Home,
    Over,
    Under,
    Push, // push=tie
    Forfeit, // forfeit=game canceled (or similar, manual process required to cancel)
    Invalid, // invalid=all speculations on same side
    Void // void=unresolved after variable void time and voided by user
}
enum PositionType {
    Upper,
    Lower
}

// user speculation represents any speculation on a contest made by a user
struct Position {
    uint256 upperAmount;
    uint256 lowerAmount;
    bool claimed;
}
