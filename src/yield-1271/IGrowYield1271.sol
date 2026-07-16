// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

/// @notice Kind of yield operation routed through a venue adapter.
enum OperationKind {
    DEPOSIT,
    REDEEM
}

/**
 * @notice One yield operation executed by the executor on behalf of `msg.sender`.
 * @param adapter Venue adapter the operation is routed through. Must be allowlisted
 *        in the executor's registry for the requested kind.
 * @param kind DEPOSIT moves `amount` of `adapter.asset()` into the venue;
 *        REDEEM moves `amount` of `adapter.positionToken()` out of the venue.
 * @param amount Source-token amount. `type(uint256).max` means the caller's full
 *        source-token balance at execution time.
 */
struct Operation {
    IYieldAdapter adapter;
    OperationKind kind;
    uint256 amount;
}

/**
 * @notice Uniform venue adapter interface. All protocol-specific logic (Aave, Morpho,
 *         future venues) lives behind this interface so the executor and the EIP-1271
 *         policy signer never branch on protocol.
 *
 * @dev Mirrors the pattern of Morpho VaultV2's `IAdapter` (allocate/deallocate with a
 *      uniform quantitative return), lifted one layer up: `deposit`/`redeem` return the
 *      amount credited so a protocol-agnostic loss cap can be enforced by the caller.
 *
 *      Flow contract with the executor:
 *      - The executor transfers the exact source-token amount to the adapter *before*
 *        calling `deposit`/`redeem`; adapters never pull funds.
 *      - Adapters must send all output directly to `receiver` and end the call without
 *        retaining source or output tokens (donation-tolerant: pre-existing balances
 *        may remain, new accumulation must not happen).
 *      - `asset` and `positionToken` must be immutable for the adapter's lifetime.
 */
interface IYieldAdapter {
    /// @notice Underlying token deposited into the venue (e.g. USDC).
    function asset() external view returns (address);

    /// @notice Token representing the venue position (e.g. aToken, ERC-4626 share).
    function positionToken() external view returns (address);

    /// @notice Expected position tokens for depositing `assets`, at current venue state.
    function previewDeposit(uint256 assets) external view returns (uint256 shares);

    /// @notice Expected underlying for redeeming `shares`, at current venue state.
    function previewRedeem(uint256 shares) external view returns (uint256 assets);

    /**
     * @notice Deposit `assets` (already held by the adapter) into the venue,
     *         crediting position tokens directly to `receiver`.
     * @return shares Position tokens credited to `receiver`.
     */
    function deposit(uint256 assets, address receiver) external returns (uint256 shares);

    /**
     * @notice Redeem `shares` (already held by the adapter) from the venue,
     *         sending underlying directly to `receiver`.
     * @return assets Underlying sent to `receiver`.
     */
    function redeem(uint256 shares, address receiver) external returns (uint256 assets);
}

/// @notice Governance-owned adapter allowlist with directional (enter/exit) gating.
interface IGrowYieldAdapterRegistry {
    /// @notice True if new deposits may be routed through `adapter`.
    function canDeposit(address adapter) external view returns (bool);

    /// @notice True if redemptions may be routed through `adapter`.
    function canRedeem(address adapter) external view returns (bool);
}

/// @notice Generic yield executor: runs a batch of adapter operations for `msg.sender`.
interface IGrowYieldExecutor {
    /// @notice Adapter allowlist consulted for every operation.
    function registry() external view returns (IGrowYieldAdapterRegistry);

    /// @notice Maximum accepted shortfall vs. adapter preview, in basis points.
    function maxLossBps() external view returns (uint16);

    /**
     * @notice Execute `ops` sequentially. Funds always move caller -> venue -> caller;
     *         the executor and adapters never retain balances.
     * @return received Output-token amount credited to the caller per operation.
     */
    function execute(Operation[] calldata ops) external returns (uint256[] memory received);
}
