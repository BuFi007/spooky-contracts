// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.24;

import {GatewayIntentPolicy} from "../gateway-guard/GatewayIntentPolicy.sol";
import {AgentGatewayAccount} from "./AgentGatewayAccount.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {Create2} from "@openzeppelin/contracts/utils/Create2.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";

interface IAgentIdentityRegistration {
    function register(string calldata agentURI) external returns (uint256 agentId);
}

/// @notice BUFI issuance provenance. Consumers must pin this factory's approved address per chain.
/// @dev Issuance does not allocate funds or grant spending. The account still requires owner and agent signatures.
/// Revoking an issuer stops new issuance; existing provenance and the account owner's recovery remain unchanged.
contract AgentGatewayAccountFactory is EIP712, ReentrancyGuard, IERC721Receiver {
    struct CreateAuthorization {
        address owner;
        address agent;
        bytes32 tokenURIHash;
        bytes32 routesHash;
        address router;
        uint256 maxExpiryBlocks;
        bytes32 nonce;
        uint64 deadline;
    }

    struct Issuance {
        address owner;
        address initialAgent;
        address issuer;
        uint256 identityId;
    }

    bytes32 public constant CREATE_TYPEHASH = keccak256(
        "CreateAuthorization(address owner,address agent,bytes32 tokenURIHash,bytes32 routesHash,address router,uint256 maxExpiryBlocks,bytes32 nonce,uint64 deadline)"
    );
    address public immutable administrator;
    address public immutable identityRegistry;
    address public immutable gatewayWallet;
    // Pin the compiled account without embedding its large creation code in the factory's deployed runtime.
    bytes32 public immutable accountCreationCodeHash;
    mapping(address => bool) public issuers;
    mapping(address => mapping(bytes32 => address)) public accountOfCreation;
    mapping(address => Issuance) public issuances;
    mapping(uint256 => address) public accountOfIdentity;
    bool private _registering;

    event IssuerAuthorized(address indexed issuer, bool allowed);
    event AccountIssued(
        address indexed account,
        uint256 indexed identityId,
        address indexed owner,
        address registry,
        address initialAgent,
        address issuer
    );
    error Refused();

    constructor(address administrator_) EIP712("BUFI Agent Gateway Factory", "1") {
        if (administrator_.code.length == 0 || (block.chainid != 5042 && block.chainid != 5042002)) {
            revert Refused();
        }
        administrator = administrator_;
        identityRegistry = block.chainid == 5042002
            ? address(0x8004A818BFB912233c491871b3d84c89A494BD9e)
            : address(0x8004A169FB4a3325136EB29fA0ceB6D2e539a432);
        gatewayWallet = block.chainid == 5042002
            ? address(0x0077777d7EBA4688BDeF3E311b846F25870A19B9)
            : address(0x77777777Dcc4d5A8B6E418Fd04D8997ef11000eE);
        if (identityRegistry.code.length == 0 || gatewayWallet.code.length == 0) revert Refused();
        accountCreationCodeHash = keccak256(type(AgentGatewayAccount).creationCode);
    }

    function setIssuer(address issuer, bool allowed) external {
        if (msg.sender != administrator || issuer == address(0)) revert Refused();
        issuers[issuer] = allowed;
        emit IssuerAuthorized(issuer, allowed);
    }

    function creationDigest(CreateAuthorization memory authorization) public view returns (bytes32) {
        return _hashTypedDataV4(keccak256(abi.encode(CREATE_TYPEHASH, authorization)));
    }

    function isIssuedAccount(address account) external view returns (bool) {
        return issuances[account].owner != address(0);
    }

    /// @notice Register, deploy and custody in one transaction, with exact owner-approved configuration.
    function createAccount(
        CreateAuthorization calldata authorization,
        string calldata agentURI,
        AgentGatewayAccount.Route[] calldata routes,
        bytes calldata accountCreationCode,
        bytes calldata ownerSignature
    ) external nonReentrant returns (AgentGatewayAccount account) {
        if (
            !issuers[msg.sender] || block.timestamp >= authorization.deadline
                || accountOfCreation[authorization.owner][authorization.nonce] != address(0)
                || authorization.tokenURIHash != keccak256(bytes(agentURI))
                || authorization.routesHash != keccak256(abi.encode(routes))
                || keccak256(accountCreationCode) != accountCreationCodeHash
                || !_ownerSigned(authorization.owner, creationDigest(authorization), ownerSignature)
        ) revert Refused();
        _registering = true;
        uint256 id = IAgentIdentityRegistration(identityRegistry).register(agentURI);
        _registering = false;
        if (accountOfIdentity[id] != address(0) || IERC721(identityRegistry).ownerOf(id) != address(this)) {
            revert Refused();
        }
        bytes memory initialization = abi.encodePacked(
            accountCreationCode,
            abi.encode(
                authorization.owner,
                authorization.agent,
                identityRegistry,
                id,
                gatewayWallet,
                uint32(26),
                authorization.maxExpiryBlocks,
                authorization.router,
                routes
            )
        );
        account = AgentGatewayAccount(
            Create2.deploy(0, keccak256(abi.encode(authorization.owner, authorization.nonce)), initialization)
        );
        IERC721(identityRegistry).safeTransferFrom(address(this), address(account), id);
        if (IERC721(identityRegistry).ownerOf(id) != address(account) || account.identityEpoch() != 1) {
            revert Refused();
        }
        accountOfCreation[authorization.owner][authorization.nonce] = address(account);
        issuances[address(account)] = Issuance(authorization.owner, authorization.agent, msg.sender, id);
        accountOfIdentity[id] = address(account);
        emit AccountIssued(address(account), id, authorization.owner, identityRegistry, authorization.agent, msg.sender);
    }

    function onERC721Received(address, address from, uint256 tokenId, bytes calldata)
        external
        view
        override
        returns (bytes4)
    {
        if (
            !_registering || msg.sender != identityRegistry || from != address(0)
                || IERC721(identityRegistry).ownerOf(tokenId) != address(this)
        ) revert Refused();
        return IERC721Receiver.onERC721Received.selector;
    }

    function _ownerSigned(address owner, bytes32 hash, bytes memory signature) private view returns (bool) {
        if (owner.code.length == 0) {
            (address signer, ECDSA.RecoverError error, bytes32 errorArg) = ECDSA.tryRecover(hash, signature);
            return error == ECDSA.RecoverError.NoError && errorArg == bytes32(0) && signer == owner && owner != address(0);
        }
        return GatewayIntentPolicy.isValidERC1271(owner, hash, signature, 500_000);
    }
}
