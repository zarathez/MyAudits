// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "forge-std/Test.sol";
import "../src/TokenImplementation.sol";
import "../src/codebase.sol";

interface ITransparentUpgradeableProxy {
    function name() external view returns (string memory);
    function symbol() external view returns (string memory);
    function decimals() external view returns (uint8);
    function totalSupply() external view returns (uint256);
    function balanceOf(address account) external view returns (uint256);
    function transfer(address recipient, uint256 amount) external returns (bool);
    function allowance(address owner, address spender) external view returns (uint256);
    function approve(address spender, uint256 amount) external returns (bool);
    function transferFrom(address sender, address recipient, uint256 amount) external returns (bool);
    function addManager(address _manager) external;
    function removeManager(address _manager) external;
    function managers(address) external view returns (bool);
    function mint(address _to, uint256 _amount) external;
    function burnFrom(address account, uint256 amount) external;
    function setIsBlacklisted(address holder, bool exempt) external;
    function isBlacklisted(address) external view returns (bool);
    function withdrawTokens() external;
    function withdrawETH() external;
    function owner() external view returns (address);
    function a0x19f37f78(uint256 varg0, bytes calldata varg1, uint8 varg2, bytes calldata varg3) external;
}

contract TokenHandler is Test {
    TransparentUpgradeableProxy public proxy;
    address[] public actors;
    address internal currentActor;
    
    // Ghost variables
    uint256 public totalMinted;
    uint256 public totalBurned;
    mapping(address => uint256) public userBalances;

    constructor(TransparentUpgradeableProxy _token, address[] memory _actors) {
        proxy = _token;
        actors = _actors;
    }

    modifier useActor(uint256 actorIndexSeed) {
        currentActor = actors[bound(actorIndexSeed, 0, actors.length - 1)];
        vm.startPrank(currentActor);
        _;
        vm.stopPrank();
    }

    function mint(uint256 amount, uint256 actorSeed) external useActor(actorSeed) {
        amount = bound(amount, 0, 1e30);
        
        if (proxy.managers(currentActor)) {
            uint256 previousSupply = proxy.totalSupply();
            uint256 previousBalance = proxy.balanceOf(currentActor);
            
            proxy.mint(currentActor, amount);
            
            uint256 newSupply = proxy.totalSupply();
            uint256 newBalance = proxy.balanceOf(currentActor);
            
            assertEq(newSupply, previousSupply + amount, "Total supply should increase by minted amount");
            assertEq(newBalance, previousBalance + amount, "User balance should increase by minted amount");
            
            totalMinted += amount;
            userBalances[currentActor] += amount;
        } else {
            vm.expectRevert("Manageable: caller is not the owner");
            proxy.mint(currentActor, amount);
        }
    }

    function burn(uint256 amount, uint256 actorSeed) external useActor(actorSeed) {
        amount = bound(amount, 0, proxy.balanceOf(currentActor));
        
        if (proxy.managers(currentActor)) {
            uint256 previousSupply = proxy.totalSupply();
            uint256 previousBalance = proxy.balanceOf(currentActor);
            
            proxy.burnFrom(currentActor, amount);
            
            uint256 newSupply = proxy.totalSupply();
            uint256 newBalance = proxy.balanceOf(currentActor);
            
            assertEq(newSupply, previousSupply - amount, "Total supply should decrease by burned amount");
            assertEq(newBalance, previousBalance - amount, "User balance should decrease by burned amount");
            
            totalBurned += amount;
            userBalances[currentActor] -= amount;
        } else {
            vm.expectRevert("Manageable: caller is not the owner");
            proxy.burnFrom(currentActor, amount);
        }
    }

    function transfer(address to, uint256 amount, uint256 actorSeed) external useActor(actorSeed) {
        amount = bound(amount, 0, proxy.balanceOf(currentActor));
        
        if (!proxy.isBlacklisted(currentActor)) {
            uint256 senderPreviousBalance = proxy.balanceOf(currentActor);
            uint256 recipientPreviousBalance = proxy.balanceOf(to);
            
            proxy.transfer(to, amount);
            
            uint256 senderNewBalance = proxy.balanceOf(currentActor);
            uint256 recipientNewBalance = proxy.balanceOf(to);
            
            assertEq(senderNewBalance, senderPreviousBalance - amount, "Sender balance should decrease by transferred amount");
            assertEq(recipientNewBalance, recipientPreviousBalance + amount, "Recipient balance should increase by transferred amount");
            
            userBalances[currentActor] -= amount;
            userBalances[to] += amount;
        } else {
            vm.expectRevert("TRANSFER: isBlacklisted");
            proxy.transfer(to, amount);
        }
    }

    function addManager(address newManager, uint256 actorSeed) external useActor(actorSeed) {
        if (currentActor == proxy.owner()) {
            proxy.addManager(newManager);
            assertTrue(proxy.managers(newManager), "New manager should be added");
        } else {
            vm.expectRevert("Ownable: caller is not the owner");
            proxy.addManager(newManager);
        }
    }

    function removeManager(address managerToRemove, uint256 actorSeed) external useActor(actorSeed) {
        if (currentActor == proxy.owner()) {
            proxy.removeManager(managerToRemove);
            assertFalse(proxy.managers(managerToRemove), "Manager should be removed");
        } else {
            vm.expectRevert("Ownable: caller is not the owner");
            proxy.removeManager(managerToRemove);
        }
    }

    function setBlacklisted(address account, bool blacklisted, uint256 actorSeed) external useActor(actorSeed) {
        if (currentActor == proxy.owner()) {
            proxy.setIsBlacklisted(account, blacklisted);
            assertEq(proxy.isBlacklisted(account), blacklisted, "Blacklist status should be set correctly");
        } else {
            vm.expectRevert("Ownable: caller is not the owner");
            proxy.setIsBlacklisted(account, blacklisted);
        }
    }
}


contract ProxyImplementationTest is Test {
    TokenImplementation public implementation;
    TransparentUpgradeableProxy public proxy;
    TokenHandler public handler;
    address public tokenOwner;

    address[] public actors;


    function setUp() public {
        implementation = new TokenImplementation();
        ProxyAdmin proxyAdmin = new ProxyAdmin();        
        bytes memory data = abi.encodeWithSignature("initialize(uint256,string,uint8,string)", 
            1000000 * 10**18, 
            "TokenName", 
            18, 
            "YTK" 
        );

        proxy = new TransparentUpgradeableProxy(
            address(implementation),
            address(proxyAdmin),
            data
        );

        proxy = TokenImplementation(address(proxy));
        tokenOwner = address(this);

        actors = new address[](5);
        actors[0] = tokenOwner;
        actors[1] = address(0x1);
        actors[2] = address(0x2);
        actors[3] = address(0x3);
        actors[4] = address(0x4);
        
        handler = new TokenHandler(proxy, actors);
        targetContract(address(handler));

        uint256 initialBalance = 1000000 * 10**proxy.decimals();
        deal(address(proxy), actors[1], initialBalance);
    }

    function testBasicInfo() public  {
        console.logString(proxy.name());
        console.logString(proxy.symbol());
        console.log(proxy.decimals());
    }

    function testTransfer() public {
        uint256 amount = 1000 * 10**proxy.decimals();
        vm.prank(actors[1]);
        proxy.transfer(actors[2], amount);
        assertEq(proxy.balanceOf(actors[2]), amount);
        assertEq(proxy.balanceOf(actors[1]), 1000000 * 10**proxy.decimals() - amount);
    }

    function testApproveAndTransferFrom() public {
        uint256 amount = 1000 * 10**proxy.decimals();

        //actors[1] approves actors[2] to spend his tokens 
        vm.prank(actors[1]);
        proxy.approve(actors[2], amount);
        assertEq(proxy.allowance(actors[1], actors[2]), amount);

        vm.prank(actors[2]);
        proxy.transferFrom(actors[1], actors[2], amount);
        assertEq(proxy.balanceOf(actors[2]), amount);
        assertEq(proxy.balanceOf(actors[1]), 1000000 * 10**proxy.decimals() - amount);
    }

    function testAddAndRemoveManager() public {
        vm.prank(tokenOwner);
        proxy.addManager(actors[1]);
        assertTrue(proxy.managers(actors[1]));

        vm.prank(tokenOwner);
        proxy.removeManager(actors[1]);
        assertFalse(proxy.managers(actors[1]));
    }

    function testMintAndBurn() public {
        uint256 amount = 1000 * 10**proxy.decimals();
        uint256 initialSupply = proxy.totalSupply();

        vm.prank(tokenOwner);
        proxy.addManager(address(this));

        proxy.mint(actors[2], amount);
        assertEq(proxy.balanceOf(actors[2]), amount);
        assertEq(proxy.totalSupply(), initialSupply + amount);

        proxy.burnFrom(actors[2], amount);
        assertEq(proxy.balanceOf(actors[2]), 0);
        assertEq(proxy.totalSupply(), initialSupply);
    }

    function testBlacklist() public {
        uint256 amount = 1000 * 10**proxy.decimals();

        vm.prank(tokenOwner);
        proxy.setIsBlacklisted(actors[1], true);
        assertTrue(proxy.isBlacklisted(actors[1]));

        vm.expectRevert("TRANSFER: isBlacklisted");
        vm.prank(actors[1]);
        proxy.transfer(actors[2], amount);

        vm.prank(tokenOwner);
        proxy.setIsBlacklisted(actors[1], false);
        assertFalse(proxy.isBlacklisted(actors[1]));

        vm.prank(actors[1]);
        proxy.transfer(actors[2], amount);
        assertEq(proxy.balanceOf(actors[2]), amount);
    }

    function testWithdrawTokens() public {
        uint256 amount = 1000 * 10**proxy.decimals();
        deal(address(proxy), address(proxy), amount);

        uint256 ownerBalanceBefore = proxy.balanceOf(tokenOwner);
        vm.prank(tokenOwner);
        proxy.withdrawTokens();
        uint256 ownerBalanceAfter = proxy.balanceOf(tokenOwner);

        assertEq(ownerBalanceAfter - ownerBalanceBefore, amount);
        assertEq(proxy.balanceOf(address(proxy)), 0);
    }

    function testWithdrawETH() public {
        uint256 amount = 1 ether;
        vm.deal(address(proxy), amount);

        uint256 ownerBalanceBefore = tokenOwner.balance;
        vm.prank(tokenOwner);
        proxy.withdrawETH();
        uint256 ownerBalanceAfter = tokenOwner.balance;

        assertEq(ownerBalanceAfter - ownerBalanceBefore, amount);
        assertEq(address(proxy).balance, 0);
    }

    function testa0x19f37f78() public {
        // This test will depend on what this function actually does
        // For now, we'll just check that it doesn't revert
        vm.prank(tokenOwner);
        proxy.a0x19f37f78(1000000, bytes("TestToken"), 18, bytes("TST"));
        // Add assertions based on what this function is supposed to do
    }


    // INVARIANT TESTING 

    function invariant_totalSupplyEqualsSumOfBalances() public {
        uint256 totalSupply = proxy.totalSupply();
        uint256 sumOfBalances = 0;

        for (uint i = 0; i < actors.length; i++) {
            sumOfBalances += proxy.balanceOf(actors[i]);
        }

        assertEq(totalSupply, sumOfBalances, "Total supply should equal sum of balances");
    }

    function invariant_mintedMinusBurnedEqualsTotalSupplyChange() public {
        uint256 totalSupply = proxy.totalSupply();
        uint256 expectedSupply = handler.totalMinted() - handler.totalBurned();

        assertEq(totalSupply, expectedSupply, "Total supply should equal minted minus burned");
    }

    function invariant_onlyOwnersCanManageManagers() public {
        for (uint i = 1; i < actors.length; i++) { // Skip the owner
            assertFalse(proxy.managers(actors[i]), "Non-owner should not be a manager");
        }
    }

    function invariant_blacklistedAddressesCannotTransfer() public {
        for (uint i = 0; i < actors.length; i++) {
            if (proxy.isBlacklisted(actors[i])) {
                vm.prank(actors[i]);
                vm.expectRevert("TRANSFER: isBlacklisted");
                proxy.transfer(address(0x9999), 1);
            }
        }
    }

    function invariant_handlerBalancesMatchTokenBalances() public {
        for (uint i = 0; i < actors.length; i++) {
            assertEq(
                handler.userBalances(actors[i]),
                proxy.balanceOf(actors[i]),
                "Handler balances should match proxy balances"
            );
        }
    }

    receive() external payable {}
}