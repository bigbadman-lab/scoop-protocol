// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {ScoopJson} from "./libraries/ScoopJson.sol";

/**
 * @title ScoopToken
 * @notice Production fixed-supply ERC-20 for a SCOOP Protocol V1 market launch.
 * @dev Mints the entire `MAX_SUPPLY` to `supplyRecipient_` at construction. There is no
 *      post-deployment mint authority, owner, pause, tax, transfer restriction, or metadata setter.
 *
 *      Presentation metadata (logo, description, socials) and launch attribution (`deployer`,
 *      `launchFactory`) are write-once via the constructor and exposed for terminal discovery,
 *      including ERC-7572-style `contractURI()`. Metadata never affects economics.
 */
contract ScoopToken is ERC20 {
    error ZeroRecipient();
    error ZeroDeployer();
    error ZeroLaunchFactory();

    /// @notice Hard-fixed launch supply for every standard SCOOP market token.
    uint256 public constant MAX_SUPPLY = 1_000_000_000 ether;

    struct Socials {
        string twitter;
        string telegram;
        string discord;
        string website;
        string farcaster;
    }

    /// @dev Original external launch caller (`ScoopFactory.launch` / `launchAndBuy` msg.sender).
    address public immutable deployer;
    /// @dev Canonical ScoopFactory that performed the launch.
    address public immutable launchFactory;

    string private _logo;
    string private _description;
    string private _twitter;
    string private _telegram;
    string private _discord;
    string private _website;
    string private _farcaster;

    constructor(
        string memory name_,
        string memory symbol_,
        address supplyRecipient_,
        address deployer_,
        address launchFactory_,
        string memory logo_,
        string memory description_,
        Socials memory socials_
    ) ERC20(name_, symbol_) {
        if (supplyRecipient_ == address(0)) revert ZeroRecipient();
        if (deployer_ == address(0)) revert ZeroDeployer();
        if (launchFactory_ == address(0)) revert ZeroLaunchFactory();

        deployer = deployer_;
        launchFactory = launchFactory_;
        _logo = logo_;
        _description = description_;
        _twitter = socials_.twitter;
        _telegram = socials_.telegram;
        _discord = socials_.discord;
        _website = socials_.website;
        _farcaster = socials_.farcaster;

        _mint(supplyRecipient_, MAX_SUPPLY);
    }

    function logo() external view returns (string memory) {
        return _logo;
    }

    function description() external view returns (string memory) {
        return _description;
    }

    function socials()
        external
        view
        returns (
            string memory twitter,
            string memory telegram,
            string memory discord,
            string memory website,
            string memory farcaster
        )
    {
        return (_twitter, _telegram, _discord, _website, _farcaster);
    }

    function getTokenInfo()
        external
        view
        returns (address deployer_, string memory logo_, string memory description_, Socials memory socials_)
    {
        deployer_ = deployer;
        logo_ = _logo;
        description_ = _description;
        socials_ = Socials({
            twitter: _twitter, telegram: _telegram, discord: _discord, website: _website, farcaster: _farcaster
        });
    }

    /// @notice ERC-7572-style inline JSON data URI. Presentation only.
    function contractURI() external view returns (string memory) {
        return ScoopJson.tokenContractUri(name(), symbol(), _description, _logo, _website);
    }
}
