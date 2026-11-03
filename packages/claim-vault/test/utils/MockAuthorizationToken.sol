// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.23;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";

/// @notice Local EIP-3009 signature/nonce model; no provider or live token is used.
contract MockAuthorizationToken is ERC20, EIP712 {
    bytes32 constant RECEIVE_TYPEHASH = keccak256(
        "ReceiveWithAuthorization(address from,address to,uint256 value,uint256 validAfter,uint256 validBefore,bytes32 nonce)"
    );
    mapping(address => mapping(bytes32 => bool)) public authorizationState;
    bool public chargeFee;
    bool public skipTransfer;

    constructor() ERC20("USDC", "USDC") EIP712("USDC", "2") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function setChargeFee(bool value) external {
        chargeFee = value;
    }

    function setSkipTransfer(bool value) external {
        skipTransfer = value;
    }

    function authorizationDigest(
        address from,
        address to,
        uint256 value,
        uint256 validAfter,
        uint256 validBefore,
        bytes32 nonce
    ) public view returns (bytes32) {
        return _hashTypedDataV4(
            keccak256(abi.encode(RECEIVE_TYPEHASH, from, to, value, validAfter, validBefore, nonce))
        );
    }

    function receiveWithAuthorization(
        address from,
        address to,
        uint256 value,
        uint256 validAfter,
        uint256 validBefore,
        bytes32 nonce,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external {
        require(msg.sender == to, "CALLER MUST BE PAYEE");
        require(block.timestamp > validAfter && block.timestamp < validBefore, "AUTHORIZATION TIME");
        require(!authorizationState[from][nonce], "AUTHORIZATION USED");
        require(
            ECDSA.recover(authorizationDigest(from, to, value, validAfter, validBefore, nonce), v, r, s) == from,
            "INVALID AUTHORIZATION"
        );
        authorizationState[from][nonce] = true;
        if (!skipTransfer) _transfer(from, to, value);
    }

    function _transfer(address from, address to, uint256 amount) internal override {
        uint256 fee = chargeFee ? amount / 100 : 0;
        if (fee != 0) super._transfer(from, address(0xdead), fee);
        super._transfer(from, to, amount - fee);
    }
}
