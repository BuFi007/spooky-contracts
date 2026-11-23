// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {MemoConduit, IAddressBook} from "../src/rails/MemoConduit.sol";

interface Vm {
    function prank(address) external;
    function chainId(uint256) external;
    function expectRevert() external;
    function expectRevert(bytes4) external;
    function expectRevert(bytes calldata) external;
    function expectEmit(bool, bool, bool, bool, address) external;
}

contract MemoV1MockAddressBook is IAddressBook {
    mapping(address => address[]) internal _allowed;

    function setAllowed(address account, address recipient) external {
        _allowed[account].push(recipient);
    }

    function clearAllowed(address account) external {
        delete _allowed[account];
    }

    function getAllowedRecipients(address account) external view override returns (address[] memory) {
        return _allowed[account];
    }
}

contract MemoV1MockToken is ERC20 {
    uint8 public receiveMode;
    bytes32 public lastNonce;
    bytes public lastSignature;

    MemoConduit public reenterTarget;
    address public reenterFrom;
    address public reenterRecipient;
    uint256 public reenterAmount;
    bytes32 public reenterMemoId;

    constructor() ERC20("Mock USDC", "USDC") {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function setReceiveMode(uint8 mode) external {
        receiveMode = mode;
    }

    function configureReentrancy(
        MemoConduit target,
        address from,
        address recipient,
        uint256 amount,
        bytes32 memoId
    ) external {
        reenterTarget = target;
        reenterFrom = from;
        reenterRecipient = recipient;
        reenterAmount = amount;
        reenterMemoId = memoId;
        receiveMode = 3;
    }

    function receiveWithAuthorization(
        address from,
        address to,
        uint256 value,
        uint256 validAfter,
        uint256 validBefore,
        bytes32 nonce,
        bytes calldata signature
    ) external {
        lastNonce = nonce;
        lastSignature = signature;

        uint8 mode = receiveMode;
        if (mode == 1) {
            _transfer(from, to, value - 1);
            return;
        }
        if (mode == 2) {
            _transfer(from, to, value);
            _mint(to, 1);
            return;
        }
        if (mode == 3) {
            receiveMode = 0;
            _transfer(from, to, value);
            reenterTarget.payWithMemo(
                address(this),
                reenterFrom,
                reenterRecipient,
                reenterAmount,
                validAfter,
                validBefore,
                reenterMemoId,
                "reenter",
                signature
            );
            return;
        }
        _transfer(from, to, value);
    }
}

contract MemoConduitTest {
    Vm internal constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    MemoV1MockAddressBook internal book;
    MemoV1MockToken internal token;
    MemoV1MockToken internal unsupportedToken;
    MemoConduit internal conduit;

    address internal payer = address(0xA11CE);
    address internal recipient = address(0xB0B);
    address internal otherRecipient = address(0xC0C0);

    function setUp() public {
        book = new MemoV1MockAddressBook();
        token = new MemoV1MockToken();
        unsupportedToken = new MemoV1MockToken();

        address[] memory tokens = new address[](1);
        tokens[0] = address(token);
        conduit = new MemoConduit(book, tokens);

        book.setAllowed(payer, otherRecipient);
        book.setAllowed(payer, recipient);
        token.mint(payer, 1_000e6);
    }

    function test_constructor_revertsOnZeroAddressBook() public {
        address[] memory tokens = new address[](1);
        tokens[0] = address(token);

        vm.expectRevert(MemoConduit.ZeroAddress.selector);
        new MemoConduit(IAddressBook(address(0)), tokens);
    }

    function test_constructor_revertsOnZeroToken() public {
        address[] memory tokens = new address[](2);
        tokens[0] = address(token);
        tokens[1] = address(0);

        vm.expectRevert(MemoConduit.ZeroAddress.selector);
        new MemoConduit(book, tokens);
    }

    function test_constructor_recordsAddressBookAndSupportedTokens() public view {
        require(address(conduit.ADDRESS_BOOK()) == address(book), "address book");
        require(conduit.supportedToken(address(token)), "supported token");
        require(!conduit.supportedToken(address(unsupportedToken)), "unsupported token");
    }

    function test_payWithMemo_happyPath_emitsEvent_preservesDonation_recordsCommitment() public {
        token.mint(address(conduit), 77);
        bytes32 memoId = keccak256("memo-happy");
        bytes memory memoData = bytes("invoice-2026-001");
        bytes memory sig = hex"deadbeef";
        bytes32 expectedNonce = conduit.memoPaymentNonceOf(
            address(token), payer, recipient, 250e6, 10, 1000, memoId, memoData
        );

        vm.expectEmit(true, true, true, true, address(conduit));
        emit MemoConduit.MemoConduitPayment(memoId, payer, recipient, address(token), 250e6, memoData);

        conduit.payWithMemo(address(token), payer, recipient, 250e6, 10, 1000, memoId, memoData, sig);

        require(conduit.memoPaymentCommitment(payer, memoId) == expectedNonce, "commitment");
        require(token.lastNonce() == expectedNonce, "derived nonce forwarded");
        require(keccak256(token.lastSignature()) == keccak256(sig), "sig forwarded");
        require(token.balanceOf(address(conduit)) == 77, "prior donation preserved");
        require(token.balanceOf(recipient) == 250e6, "recipient paid");
        require(token.balanceOf(payer) == 750e6, "payer debited");
    }

    function test_payWithMemo_revertsOnZeroAmount() public {
        vm.expectRevert(MemoConduit.ZeroAmount.selector);
        conduit.payWithMemo(address(token), payer, recipient, 0, 0, 1000, keccak256("m0"), "memo", hex"01");
    }

    function test_payWithMemo_revertsOnZeroRecipient() public {
        vm.expectRevert(MemoConduit.ZeroAddress.selector);
        conduit.payWithMemo(address(token), payer, address(0), 100e6, 0, 1000, keccak256("m-zero-r"), "memo", hex"01");
    }

    function test_payWithMemo_revertsOnUnsupportedToken() public {
        vm.expectRevert(abi.encodeWithSelector(MemoConduit.TokenNotSupported.selector, address(unsupportedToken)));
        conduit.payWithMemo(
            address(unsupportedToken), payer, recipient, 100e6, 0, 1000, keccak256("m-unsup"), "memo", hex"01"
        );
    }

    function test_payWithMemo_revertsOnMemoAlreadyPaid() public {
        bytes32 memoId = keccak256("m-dup");
        conduit.payWithMemo(address(token), payer, recipient, 100e6, 0, 1000, memoId, "memo", hex"01");

        vm.expectRevert(abi.encodeWithSelector(MemoConduit.MemoAlreadyPaid.selector, payer, memoId));
        conduit.payWithMemo(address(token), payer, recipient, 100e6, 0, 2000, memoId, "memo", hex"01");
    }

    function test_payWithMemo_revertsOnRecipientNotAllowlisted() public {
        address unallowlisted = address(0xDEAD);

        vm.expectRevert(abi.encodeWithSelector(MemoConduit.RecipientNotAllowlisted.selector, payer, unallowlisted));
        conduit.payWithMemo(address(token), payer, unallowlisted, 100e6, 0, 1000, keccak256("m-na1"), "memo", hex"01");

        book.clearAllowed(payer);
        vm.expectRevert(abi.encodeWithSelector(MemoConduit.RecipientNotAllowlisted.selector, payer, recipient));
        conduit.payWithMemo(address(token), payer, recipient, 100e6, 0, 1000, keccak256("m-na2"), "memo", hex"01");
    }

    function test_payWithMemo_revertsOnBalanceChanged_shortPull() public {
        token.mint(address(conduit), 100);
        token.setReceiveMode(1);

        vm.expectRevert(abi.encodeWithSelector(MemoConduit.BalanceChanged.selector, uint256(100), uint256(99)));
        conduit.payWithMemo(address(token), payer, recipient, 50e6, 0, 1000, keccak256("m-short"), "memo", hex"01");
    }

    function test_payWithMemo_revertsOnBalanceChanged_excessSurplus() public {
        token.mint(address(conduit), 100);
        token.setReceiveMode(2);

        vm.expectRevert(abi.encodeWithSelector(MemoConduit.BalanceChanged.selector, uint256(100), uint256(101)));
        conduit.payWithMemo(address(token), payer, recipient, 50e6, 0, 1000, keccak256("m-excess"), "memo", hex"01");
    }

    function test_payWithMemo_revertsOnReentrancy() public {
        token.configureReentrancy(conduit, payer, recipient, 25e6, keccak256("m-inner"));

        vm.expectRevert(ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        conduit.payWithMemo(address(token), payer, recipient, 50e6, 0, 1000, keccak256("m-outer"), "memo", hex"01");
    }

    function test_memoPaymentNonceOf_bindsEveryField() public {
        bytes32 memoId = keccak256("m-bind");
        bytes memory memoData = bytes("hello");
        bytes32 base = conduit.memoPaymentNonceOf(address(token), payer, recipient, 100e6, 1, 100, memoId, memoData);

        bytes32 manual = keccak256(
            abi.encode(
                conduit.MEMO_PAYMENT_NONCE_TYPEHASH(),
                block.chainid,
                address(conduit),
                address(token),
                payer,
                recipient,
                uint256(100e6),
                uint256(1),
                uint256(100),
                memoId,
                keccak256(memoData)
            )
        );
        require(base == manual, "manual hash mismatch");

        require(
            conduit.memoPaymentNonceOf(address(unsupportedToken), payer, recipient, 100e6, 1, 100, memoId, memoData)
                != base,
            "token"
        );
        require(
            conduit.memoPaymentNonceOf(address(token), address(0x1111), recipient, 100e6, 1, 100, memoId, memoData)
                != base,
            "from"
        );
        require(
            conduit.memoPaymentNonceOf(address(token), payer, otherRecipient, 100e6, 1, 100, memoId, memoData) != base,
            "recipient"
        );
        require(
            conduit.memoPaymentNonceOf(address(token), payer, recipient, 101e6, 1, 100, memoId, memoData) != base,
            "amount"
        );
        require(
            conduit.memoPaymentNonceOf(address(token), payer, recipient, 100e6, 2, 100, memoId, memoData) != base,
            "validAfter"
        );
        require(
            conduit.memoPaymentNonceOf(address(token), payer, recipient, 100e6, 1, 101, memoId, memoData) != base,
            "validBefore"
        );
        require(
            conduit.memoPaymentNonceOf(address(token), payer, recipient, 100e6, 1, 100, keccak256("other"), memoData)
                != base,
            "memoId"
        );
        require(
            conduit.memoPaymentNonceOf(address(token), payer, recipient, 100e6, 1, 100, memoId, bytes("world")) != base,
            "memoData"
        );

        address[] memory tokens = new address[](1);
        tokens[0] = address(token);
        MemoConduit otherConduit = new MemoConduit(book, tokens);
        require(
            otherConduit.memoPaymentNonceOf(address(token), payer, recipient, 100e6, 1, 100, memoId, memoData) != base,
            "conduit"
        );

        uint256 originalChain = block.chainid;
        vm.chainId(originalChain + 1);
        require(
            conduit.memoPaymentNonceOf(address(token), payer, recipient, 100e6, 1, 100, memoId, memoData) != base,
            "chainId"
        );
        vm.chainId(originalChain);
    }
}
