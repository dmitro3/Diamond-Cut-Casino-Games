// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.0;

import "./Common.sol";

/**
 * @title plinko game, players select a number of rows and risk and get payouts depending on the final position of the ball
 */
contract Plinko is Common {
    using SafeERC20 for IERC20;

    constructor(
        address _bankroll,
        address _vrf,
        address link_eth_feed,
        address _forwarder
    ) {
        Bankroll = IBankRoll(_bankroll);
        IChainLinkVRF = IVRFCoordinatorV2(_vrf);
        LINK_ETH_FEED = AggregatorV3Interface(link_eth_feed);
        ChainLinkVRF = _vrf;
        _trustedForwarder = _forwarder;
        kellyFractions[0] = [
            573159,
            240816,
            372158,
            267835,
            453230,
            480140,
            327817,
            384356,
            467936
        ];
        kellyFractions[1] = [
            108157,
            100164,
            100856,
            82065,
            91981,
            83772,
            68092,
            69475,
            100288
        ];
        kellyFractions[2] = [
            31369,
            25998,
            38394,
            27787,
            29334,
            29004,
            22764,
            21439,
            27190
        ];
    }

    struct PlinkoGame {
        uint256 wager;
        uint256 stopGain;
        uint256 stopLoss;
        uint256 requestID;
        address tokenAddress;
        uint64 blockNumber;
        uint32 numBets;
        uint8 risk;
        uint8 numRows;
    }

    mapping(address => PlinkoGame) plinkoGames;
    mapping(uint256 => address) plinkoIDs;
    mapping(uint8 => mapping(uint8 => mapping(uint8 => uint256))) plinkoMultipliers;
    mapping(uint8 => mapping(uint8 => bool)) isMultiplierSet;
    uint256[9][3] kellyFractions;

    /**
     * @dev event emitted at the start of the game
     * @param playerAddress address of the player that made the bet
     * @param wager wager amount
     * @param tokenAddress address of token the wager was made and payout, 0 address is considered the native coin
     * @param numRows number of rows selected
     * @param risk risk selected
     * @param numBets number of bets the player intends to make
     * @param stopGain gain value at which the betting stop if a gain is reached
     * @param stopLoss loss value at which the betting stop if a loss is reached
     */
    event Plinko_Play_Event(
        address indexed playerAddress,
        uint256 wager,
        address tokenAddress,
        uint8 numRows,
        uint8 risk,
        uint32 numBets,
        uint256 stopGain,
        uint256 stopLoss,
        uint256 VRFFee
    );

    /**
     * @dev event emitted by the VRF callback with the bet results
     * @param playerAddress address of the player that made the bet
     * @param wager wager amount
     * @param payout total payout transfered to the player
     * @param tokenAddress address of token the wager was made and payout, 0 address is considered the native coin
     * @param paths direction taken by the plinko ball at each row, true-> right, false->left
     * @param risk risk selected by player
     * @param payouts individual payouts for each bet
     * @param numGames number of games performed
     */
    event Plinko_Outcome_Event(
        address indexed playerAddress,
        uint256 wager,
        uint256 payout,
        address tokenAddress,
        uint16[] paths,
        uint8 numRows,
        uint8 risk,
        uint256[] payouts,
        uint32 numGames
    );

    /**
     * @dev event emitted when a refund is done in plinko
     * @param player address of the player reciving the refund
     * @param wager amount of wager that was refunded
     * @param tokenAddress address of token the refund was made in
     */
    event Plinko_Refund_Event(
        address indexed player,
        uint256 wager,
        address tokenAddress
    );

    error AwaitingVRF(uint256 requestID);
    error InvalidNumRows();
    error InvalidRisk();
    error InvalidNumBets(uint256 maxNumBets);
    error OnlyCoordinatorCanFulfill(address have, address want);
    error WagerAboveLimit(uint256 wager, uint256 maxWager);
    error NotAwaitingVRF();
    error BlockNumberTooLow(uint256 have, uint256 want);
    error MismatchedLength(uint256 multipliers, uint256 outcome);
    error MultiplierAlreadySet(uint8 numRows, uint8 risk);
    error InvalidNumberToSet();

    /**
     * @dev function to get current request player is await from VRF, returns 0 if none
     * @param player address of the player to get the state
     */
    function Plinko_GetState(
        address player
    ) external view returns (PlinkoGame memory) {
        return (plinkoGames[player]);
    }

    /**
     * @dev function to view the current plinko multipliers
     * @return multipliers all multipliers for all rows and risks
     */
    function Plinko_GetMultipliers()
        external
        view
        returns (uint256[17][9][3] memory multipliers)
    {
        for (uint8 r = 0; r < 3; r++) {
            for (uint8 g = 0; g < 9; g++) {
                for (uint8 i = 0; i < 17; i++) {
                    multipliers[r][g][i] = plinkoMultipliers[r][g + 8][i];
                }
            }
        }
        return multipliers;
    }

    /**
     * @dev Function to play Plinko, takes the user wager saves bet parameters and makes a request to the VRF
     * @param wager wager amount
     * @param tokenAddress address of token to bet, 0 address is considered the native coin
     * @param numBets number of bets to make, and amount of random numbers to request
     * @param stopGain treshold value at which the bets stop if a certain profit is obtained
     * @param stopLoss treshold value at which the bets stop if a certain loss is obtained
     * @param numRows number of Rows that plinko will have, range 8-16
     * @param risk risk for game, higher risk increases variance, range 0-2
     */
    function Plinko_Play(
        uint256 wager,
        address tokenAddress,
        uint8 numRows,
        uint8 risk,
        uint32 numBets,
        uint256 stopGain,
        uint256 stopLoss
    ) external payable nonReentrant {
        address msgSender = _msgSender();
        if (numRows < 8 || numRows > 16) {
            revert InvalidNumRows();
        }
        if (risk >= 3) {
            revert InvalidRisk();
        }
        if (plinkoGames[msgSender].requestID != 0) {
            revert AwaitingVRF(plinkoGames[msgSender].requestID);
        }
        if (!(numBets > 0 && numBets <= 100)) {
            revert InvalidNumBets(100);
        }

        _kellyWager(wager, tokenAddress, numRows, risk);
        uint256 fee = _transferWager(
            tokenAddress,
            wager * numBets,
            2000000,
            msgSender
        );
        uint256 id = _requestRandomWords(numBets);

        plinkoGames[msgSender] = PlinkoGame(
            wager,
            stopGain,
            stopLoss,
            id,
            tokenAddress,
            uint64(block.number),
            numBets,
            risk,
            numRows
        );
        plinkoIDs[id] = msgSender;

        emit Plinko_Play_Event(
            msgSender,
            wager,
            tokenAddress,
            numRows,
            risk,
            numBets,
            stopGain,
            stopLoss,
            fee
        );
    }

    /**
     * @dev Function to refund user in case of VRF request failling
     */
    function Plinko_Refund() external nonReentrant {
        address msgSender = _msgSender();
        PlinkoGame storage game = plinkoGames[msgSender];
        if (game.requestID == 0) {
            revert NotAwaitingVRF();
        }
        if (game.blockNumber + BLOCK_NUMBER_REFUND + 10 > block.number) {
            revert BlockNumberTooLow(
                block.number,
                game.blockNumber + BLOCK_NUMBER_REFUND + 10
            );
        }

        uint256 wager = game.wager * game.numBets;
        address tokenAddress = game.tokenAddress;

        delete (plinkoIDs[game.requestID]);
        delete (plinkoGames[msgSender]);

        if (tokenAddress == address(0)) {
            (bool success, ) = payable(msgSender).call{value: wager}("");
            if (!success) {
                revert TransferFailed();
            }
        } else {
            IERC20(tokenAddress).safeTransfer(msgSender, wager);
        }
        emit Plinko_Refund_Event(msgSender, wager, tokenAddress);
    }

    /**
     * @dev function to set the plinko multipliers, can only be called by bankroll owner
     * @param multipliers array of all multipliers for the selected number of rows and risk
     * @param numRows number of rows to set multiplier
     * @param risk risk to set multiplier
     */
    function setPlinkoMultipliers(
        uint256[] calldata multipliers,
        uint8 numRows,
        uint8 risk
    ) external {
        if (msg.sender != Bankroll.getOwner()) {
            revert NotOwner(Bankroll.getOwner(), msg.sender);
        }
        if (isMultiplierSet[risk][numRows]) {
            revert MultiplierAlreadySet(numRows, risk);
        }

        if (multipliers.length != numRows + 1) {
            revert MismatchedLength(multipliers.length, numRows + 1);
        }
        if (numRows < 8 || numRows > 16) {
            revert InvalidNumRows();
        }
        if (risk >= 3) {
            revert InvalidRisk();
        }

        for (uint8 i = 0; i < multipliers.length; i++) {
            plinkoMultipliers[risk][numRows][i] = multipliers[i];
        }
        isMultiplierSet[risk][numRows] = true;
    }

    /**
     * @dev function called by Chainlink VRF with random numbers
     * @param requestId id provided when the request was made
     * @param randomWords array of random numbers
     */
    function rawFulfillRandomWords(
        uint256 requestId,
        uint256[] memory randomWords
    ) external {
        if (msg.sender != ChainLinkVRF) {
            revert OnlyCoordinatorCanFulfill(msg.sender, ChainLinkVRF);
        }
        fulfillRandomWords(requestId, randomWords);
    }

    function fulfillRandomWords(
        uint256 requestId,
        uint256[] memory randomWords
    ) internal {
        address playerAddress = plinkoIDs[requestId];
        if (playerAddress == address(0)) revert();
        PlinkoGame storage game = plinkoGames[playerAddress];
        if (block.number > game.blockNumber + BLOCK_NUMBER_REFUND) revert();

        uint16[] memory gamesResults = new uint16[](game.numBets);
        uint256[] memory payouts = new uint256[](game.numBets);

        int256 totalValue;
        uint256 payout;
        uint32 i;
        uint256 multiplier;

        address tokenAddress = game.tokenAddress;

        for (i = 0; i < game.numBets; i++) {
            if (totalValue >= int256(game.stopGain)) {
                break;
            }
            if (totalValue <= -int256(game.stopLoss)) {
                break;
            }

            (multiplier, gamesResults[i]) = _plinkoGame(
                randomWords[i],
                game.numRows,
                game.risk
            );

            payouts[i] = (game.wager * multiplier) / 100;
            payout += payouts[i];
            totalValue += int256(payouts[i]) - int256(game.wager);
        }

        payout += (game.numBets - i) * game.wager;

        emit Plinko_Outcome_Event(
            playerAddress,
            game.wager,
            payout,
            tokenAddress,
            gamesResults,
            game.numRows,
            game.risk,
            payouts,
            i
        );
        _transferToBankroll(tokenAddress, game.wager * game.numBets);
        delete (plinkoIDs[requestId]);
        delete (plinkoGames[playerAddress]);
        if (payout != 0) {
            _transferPayout(playerAddress, payout, tokenAddress);
        }
    }

    /**
     * @dev function to get result of individual plinko game
     * @param randomWords rng to determine the result
     * @param numRows number of rows of game
     * @param risk risk level selected
     */
    function _plinkoGame(
        uint256 randomWords,
        uint8 numRows,
        uint8 risk
    ) internal view returns (uint256 multiplier, uint16 currentGameResult) {
        int8 ended = 0;
        for (uint8 g = 0; g < numRows; g++) {
            bool bitValue = _getBitValue(randomWords, g);
            if (bitValue) {
                ended += 1;
                currentGameResult = setBit(currentGameResult, g);
            } else {
                ended -= 1;
            }
        }
        uint8 multiplierSlot = uint8(ended + int8(numRows)) >> 1;
        multiplier = plinkoMultipliers[risk][numRows][multiplierSlot];
    }

    function _getBitValue(
        uint256 four_nibbles,
        uint256 index
    ) internal pure returns (bool) {
        return (four_nibbles & (1 << index)) != 0;
    }

    uint16 internal constant ONE = uint16(1);

    // Sets the bit at the given 'index' in 'self' to '1'.
    // Returns the modified value.
    function setBit(uint16 self, uint8 index) internal pure returns (uint16) {
        return self | (ONE << index);
    }

    /**
     * @dev calculates the maximum wager allowed based on the bankroll size
     */
    function _kellyWager(
        uint256 wager,
        address tokenAddress,
        uint8 numRows,
        uint8 risk
    ) internal view {
        uint256 balance;
        if (tokenAddress == address(0)) {
            balance = address(Bankroll).balance;
        } else {
            balance = IERC20(tokenAddress).balanceOf(address(Bankroll));
        }
        uint256 maxWager = (balance * kellyFractions[risk][numRows - 8]) /
            100000000;
        if (wager > maxWager) {
            revert WagerAboveLimit(wager, maxWager);
        }
    }
}