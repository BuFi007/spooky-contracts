// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.24;

import {TreasuryBridgeConduitV2} from "../src/bufi/conduit/TreasuryBridgeConduitV2.sol";
import {TreasuryConduit} from "../src/bufi/conduit/TreasuryConduit.sol";
import {TreasuryConduitPermit2} from "../src/bufi/conduit/TreasuryConduitPermit2.sol";
import {TreasuryRedeemConduit} from "../src/bufi/conduit/TreasuryRedeemConduit.sol";
import {IPermit2SignatureTransfer} from "../src/bufi/conduit/interfaces/IPermit2SignatureTransfer.sol";

interface Vm {
    function prank(address) external;
    function warp(uint256) external;
    function etch(address, bytes calldata) external;
    function expectRevert() external;
    function expectRevert(bytes4) external;
    function expectRevert(bytes calldata) external;
}

contract V2MockToken {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function receiveWithAuthorization(address from, address to, uint256 value, uint256, uint256, bytes32, bytes calldata)
        external
    {
        balanceOf[from] -= value;
        balanceOf[to] += value;
    }
}

contract V2BurnTarget {
    function burnAll(V2MockToken token, uint256 amount) external {
        token.transferFrom(msg.sender, address(0xdead), amount);
    }
}

/// @notice Deployment smoke checks. These are not the upstream Foundry suite
/// (that suite lives in the private BUFI-6900 tree and was not reachable).
contract TreasuryConduitDeployTest {
    Vm internal constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    function test_deploys_with_owner() public {
        TreasuryConduit conduit = new TreasuryConduit(address(this));
        require(conduit.owner() == address(this), "owner");
        require(conduit.INTENT_TYPEHASH() != bytes32(0), "typehash");
    }

    function test_bridge_deploys_with_owner() public {
        TreasuryBridgeConduitV2 bridge = new TreasuryBridgeConduitV2(address(this));
        require(bridge.owner() == address(this), "owner");
        require(bridge.INTENT_TYPEHASH() != bytes32(0), "typehash");
    }

    function test_redeem_deploys_with_owner() public {
        TreasuryRedeemConduit redeem = new TreasuryRedeemConduit(address(this));
        require(redeem.owner() == address(this), "owner");
    }

    function test_F21_v2ConduitsLackTargetVenueAndVaultAllowlists() public {
        TreasuryConduit conduit = new TreasuryConduit(address(this));
        TreasuryBridgeConduitV2 bridge = new TreasuryBridgeConduitV2(address(this));
        TreasuryRedeemConduit redeem = new TreasuryRedeemConduit(address(this));
        vm.expectRevert(TreasuryConduit.ZeroAddress.selector);
        conduit.setTarget(address(0), true);
        vm.expectRevert(TreasuryRedeemConduit.ZeroAddress.selector);
        redeem.setVault(address(0), true);
        vm.expectRevert(TreasuryConduit.RenounceDisabled.selector);
        conduit.renounceOwnership();
        vm.expectRevert(TreasuryRedeemConduit.RenounceDisabled.selector);
        redeem.renounceOwnership();
        vm.expectRevert(TreasuryBridgeConduitV2.RenounceDisabled.selector);
        bridge.renounceOwnership();
        require(bridge.owner() == address(this), "renounceOwnership disabled across v2 conduits");
    }

    function test_F24_permit2ConduitDeadlineUsesGreaterOrEqualWhereasErc3009UsesStrictGreater() public {
        vm.warp(1_000);
        address permit2Addr = 0x000000000022D473030F116dDEE9F6B43aC78BA3;
        address bookAddr = address(0xB00C);
        address treasury = address(0x7EA5);
        vm.etch(permit2Addr, hex"600080fd");
        vm.etch(bookAddr, hex"600080fd");
        vm.etch(treasury, hex"600080fd");

        V2MockToken tokenIn = new V2MockToken();
        V2MockToken tokenOut = new V2MockToken();
        TreasuryConduitPermit2 p2 = new TreasuryConduitPermit2(address(this), permit2Addr, bookAddr);
        p2.setPermit2Route(address(tokenIn), address(tokenIn), true);

        IPermit2SignatureTransfer.PermitTransferFrom memory permit = IPermit2SignatureTransfer.PermitTransferFrom({
            permitted: IPermit2SignatureTransfer.TokenPermissions({token: address(tokenIn), amount: 100}),
            nonce: 1,
            deadline: 1_000
        });
        TreasuryConduitPermit2.Permit2Intent memory intent = TreasuryConduitPermit2.Permit2Intent({
            operationId: keccak256("op-f24"),
            target: address(tokenIn),
            allowanceTarget: address(tokenIn),
            data: "",
            tokenIn: address(tokenIn),
            amountIn: 100,
            tokenOut: address(tokenOut),
            minOut: 1,
            recipient: treasury,
            deadline: 1_000,
            documentCommitment: bytes32(0),
            memoId: bytes32(0),
            memo: ""
        });

        vm.warp(1_001);
        vm.expectRevert(abi.encodeWithSelector(TreasuryConduit.IntentExpired.selector, uint256(1_000), uint256(1_001)));
        p2.executePermit2(permit, treasury, hex"01", intent);
    }

    function test_F25_sameTokenSwapUnderflowRevertsInSolidity0824() public {
        TreasuryConduit conduit = new TreasuryConduit(address(this));
        V2MockToken token = new V2MockToken();
        V2BurnTarget target = new V2BurnTarget();
        conduit.setTarget(address(target), true);

        address treasury = address(0x7EA5);
        token.mint(treasury, 100);

        bytes memory callData = abi.encodeCall(V2BurnTarget.burnAll, (token, 100));
        TreasuryConduit.Intent memory intent = TreasuryConduit.Intent({
            target: address(target),
            data: callData,
            tokenIn: address(token),
            amountIn: 100,
            tokenOut: address(token),
            minOut: 1,
            beneficiary: treasury,
            deadline: block.timestamp + 100,
            memoId: bytes32(0),
            memo: ""
        });
        TreasuryConduit.Authorization memory auth = TreasuryConduit.Authorization({
            token: address(token),
            from: treasury,
            value: 100,
            validAfter: 0,
            validBefore: block.timestamp + 100,
            nonce: conduit.intentNonce(intent)
        });

        vm.expectRevert(abi.encodeWithSelector(TreasuryConduit.BelowFloor.selector, uint256(0), uint256(1)));
        conduit.execute(auth, hex"01", intent);
    }

    function test_SafeTxBuilder_Arc5042_TreasuryConduitsBatch() public {
        address create2Factory = 0x4e59b44847b379578588920cA78FbF26c0B4956C;
        address safe = 0x47Dc7D18A6E3a79F696714E7D47456a49B430D09;
        address permit2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;
        address addressBook = 0x0000000d81083B16EA76dfab46B0315B0eDBF3d0;
        address lifi = 0xA4072583658Fae592A3506A42431cb6316a8d40b;
        address uniRouter = 0x8702463e73f74d0b6765aBceb314Ef07aCb92650;
        address uniNoPermit2 = 0x0000000085E102724e78eCd2F45DC9cA239Affad;
        address papyVault = 0x7610094B846657dCF166D59e42973db52c7015F9;
        address steakVault = 0xbeef0016cb2Fd5C352ea7CA08a9f54739DFa7298;
        address cctpMessenger = 0x28b5a0e9C621a5BadaA536219b3a228C8168cf5d;
        address cctpxService = 0x431871229103b780868f8C6BB820cd16ECf942BC;

        vm.etch(safe, hex"600080fd");
        vm.etch(permit2, hex"600080fd");
        vm.etch(addressBook, hex"600080fd");
        vm.etch(lifi, hex"600080fd");
        vm.etch(uniRouter, hex"600080fd");
        vm.etch(uniNoPermit2, hex"600080fd");
        vm.etch(papyVault, hex"600080fd");
        vm.etch(steakVault, hex"600080fd");
        vm.etch(cctpMessenger, hex"600080fd");
        vm.etch(cctpxService, hex"600080fd");

        bytes memory tcPayload = abi.encodePacked(
            keccak256("bufi.treasury-conduit.v2"),
            type(TreasuryConduit).creationCode,
            abi.encode(safe)
        );
        bytes memory tcp2Payload = abi.encodePacked(
            keccak256("bufi.treasury-conduit.permit2.v1"),
            type(TreasuryConduitPermit2).creationCode,
            abi.encode(safe, permit2, addressBook)
        );
        bytes memory tbcv2Payload = abi.encodePacked(
            keccak256("bufi.treasury-bridge-conduit.v2"),
            type(TreasuryBridgeConduitV2).creationCode,
            abi.encode(safe)
        );
        bytes memory trcPayload = abi.encodePacked(
            keccak256("bufi.treasury-redeem-conduit.v1"),
            type(TreasuryRedeemConduit).creationCode,
            abi.encode(safe)
        );

        vm.prank(safe);
        (bool ok1, bytes memory ret1) = create2Factory.call(tcPayload);
        require(ok1 && ret1.length == 20, "tc deploy failed");
        address tcAddr = address(bytes20(ret1));
        require(tcAddr == 0x6B33A6E3078F961892eC2A27797F2Bd1efF07327, "tc addr mismatch");

        vm.prank(safe);
        (bool ok2, bytes memory ret2) = create2Factory.call(tcp2Payload);
        require(ok2 && ret2.length == 20, "tcp2 deploy failed");
        address tcp2Addr = address(bytes20(ret2));
        require(tcp2Addr == 0xE7b973C68678888eD4824154529362AcFaC10278, "tcp2 addr mismatch");

        vm.prank(safe);
        (bool ok3, bytes memory ret3) = create2Factory.call(tbcv2Payload);
        require(ok3 && ret3.length == 20, "tbcv2 deploy failed");
        address tbcv2Addr = address(bytes20(ret3));
        require(tbcv2Addr == 0x3552726aacf5A2761991a270CdE2dba9dc2f5FCc, "tbcv2 addr mismatch");

        vm.prank(safe);
        (bool ok4, bytes memory ret4) = create2Factory.call(trcPayload);
        require(ok4 && ret4.length == 20, "trc deploy failed");
        address trcAddr = address(bytes20(ret4));
        require(trcAddr == 0x5f47FEEE01B89D8B1A1FAb4e8A52B0C4C2b7EeAa, "trc addr mismatch");

        vm.prank(safe);
        TreasuryConduit(tcAddr).setTarget(lifi, true);
        vm.prank(safe);
        TreasuryConduitPermit2(tcp2Addr).setTarget(lifi, true);
        vm.prank(safe);
        TreasuryConduitPermit2(tcp2Addr).setPermit2Route(lifi, lifi, true);
        vm.prank(safe);
        TreasuryBridgeConduitV2(tbcv2Addr).setTarget(lifi, true);
        vm.prank(safe);
        TreasuryBridgeConduitV2(tbcv2Addr).setBridge(TreasuryBridgeConduitV2.BridgeKind.CCTP_V2, cctpMessenger, true);
        vm.prank(safe);
        TreasuryBridgeConduitV2(tbcv2Addr).setBridge(TreasuryBridgeConduitV2.BridgeKind.CCTPX, cctpxService, true);
        vm.prank(safe);
        TreasuryRedeemConduit(trcAddr).setVault(papyVault, true);

        require(TreasuryConduit(tcAddr).targets(lifi), "tc target not set");
        require(TreasuryConduitPermit2(tcp2Addr).permit2Routes(lifi, lifi), "tcp2 route not set");
        require(
            TreasuryBridgeConduitV2(tbcv2Addr).bridges(TreasuryBridgeConduitV2.BridgeKind.CCTP_V2, cctpMessenger),
            "tbcv2 bridge not set"
        );
        require(TreasuryRedeemConduit(trcAddr).vaults(papyVault), "trc vault not set");
    }
}
