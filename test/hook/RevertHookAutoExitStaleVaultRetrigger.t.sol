// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {RevertHookTest} from "./RevertHook.t.sol";
import {RevertHookState} from "src/hook/RevertHookState.sol";
import {PositionModeFlags} from "src/hook/lib/PositionModeFlags.sol";
import {V4Vault} from "src/vault/V4Vault.sol";
import {InterestRateModel} from "src/vault/InterestRateModel.sol";
import {Constants as SharedConstants} from "src/shared/Constants.sol";
import {Constants} from "@uniswap/v4-core/test/utils/Constants.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IWETH9} from "@uniswap/v4-periphery/src/interfaces/external/IWETH9.sol";
import {Actions} from "@uniswap/v4-periphery/src/libraries/Actions.sol";
import { EasyPosm } from "test/utils/libraries/EasyPosm.sol";
import { IPoolManager } from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";

/// @notice Regression tests for AUTO_EXIT cleanup when a vault position has zero liquidity and zero debt.
contract RevertHookAutoExitStaleVaultRetriggerTest is RevertHookTest {
    using EasyPosm for *;

    function testAutoExitRetriggerAfterPartialRepayAndExternalDebtClearanceCleansUpInsteadOfReverting() public {
        IERC20 asset = IERC20(Currency.unwrap(currency0));
        InterestRateModel rates = new InterestRateModel(0, 0, 0, 1 << 63);
        V4Vault vault = new V4Vault(
            "Test Lending Vault", "TLV", address(asset), positionManager, rates, v4Oracle, IWETH9(address(0))
        );
        uint32 collateralFactor = uint32((uint256(1) << 32) * 9 / 10);
        vault.setTokenConfig(Currency.unwrap(currency0), collateralFactor, type(uint32).max);
        vault.setTokenConfig(Currency.unwrap(currency1), collateralFactor, type(uint32).max);
        vault.setLimits(0, 100 ether, 100 ether, 100 ether, 100 ether);
        vault.setHookAllowList(address(hook), true);
        vault.setTransformer(address(hook), true);
        hook.setVault(address(vault));

        asset.approve(address(vault), 1 ether);
        vault.deposit(1 ether, address(this));

        // Remove all LP liquidity from token3Id first while minPositionValueNative == 0,
        // then deposit into vault and borrow/repay so debt == 0 and liquidity == 0.
        uint128 liq = positionManager.getPositionLiquidity(token3Id);
        positionManager.decreaseLiquidity(
            token3Id,
            liq,
            0,
            0,
            address(this),
            block.timestamp,
            Constants.ZERO_BYTES
        );
        assertEq(positionManager.getPositionLiquidity(token3Id), 0, "liquidity drained");

        IERC721(address(positionManager)).approve(address(vault), token3Id);
        vault.create(token3Id, address(this));
        vault.approveTransform(token3Id, address(hook), true);
        assertEq(vault.loans(token3Id), 0, "debt cleared");

        RevertHookState.PositionConfig memory config;
        config.modeFlags = PositionModeFlags.MODE_AUTO_EXIT;
        config.autoExitTickLower = tickLower3 - poolKey.tickSpacing;
        config.autoExitTickUpper = type(int24).max;
        config.autoExitSwapOnLowerTrigger = true;
        config.autoExitSwapOnUpperTrigger = true;
        hook.setPositionConfig(token3Id, config);

        (uint8 modeBefore,,,,,,,,,,,,) = hook.positionConfigs(token3Id);
        assertEq(modeBefore, PositionModeFlags.MODE_AUTO_EXIT, "AUTO_EXIT armed before trigger");

        // Swap across the lower exit trigger tick.
        swapRouter.swapExactTokensForTokens({
            amountIn: 1e18,
            amountOutMin: 0,
            zeroForOne: true,
            poolKey: poolKey,
            hookData: Constants.ZERO_BYTES,
            receiver: address(this),
            deadline: block.timestamp
        });

        (uint8 modeAfter,,,,,,,,,,,,) = hook.positionConfigs(token3Id);
        assertEq(modeAfter, PositionModeFlags.MODE_NONE, "stale zero-liquidity zero-debt AUTO_EXIT must be cleaned up");
        (,, uint32 lastActivatedAfter,,,,,) = hook.positionStates(token3Id);
        assertEq(lastActivatedAfter, 0, "position must be deactivated after cleanup");
    }

    function testAutoExitZeroLiquidityStillRejectsDisallowedVault() public {
        IERC20 asset = IERC20(Currency.unwrap(currency0));
        InterestRateModel rates = new InterestRateModel(0, 0, 0, 1 << 63);
        V4Vault disallowedVault = new V4Vault(
            "Disallowed Vault", "DLV", address(asset), positionManager, rates, v4Oracle, IWETH9(address(0))
        );

        vm.prank(address(disallowedVault));
        vm.expectRevert(SharedConstants.Unauthorized.selector);
        hook.autoExit(poolKey, token3Id, false);
    }
}
