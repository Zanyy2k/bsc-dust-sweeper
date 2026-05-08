// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IERC20 {
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function transfer(address to, uint256 amount) external returns (bool);
    function approve(address spender, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
    function allowance(address owner, address spender) external view returns (uint256);
}

interface IPancakeRouter {
    function swapExactTokensForETHSupportingFeeOnTransferTokens(
        uint amountIn,
        uint amountOutMin,
        address[] calldata path,
        address to,
        uint deadline
    ) external;
    function WETH() external pure returns (address);
}

contract DustSweeper {
    address public owner;
    address public feeRecipient;
    uint256 public feeBps; // 1500 = 15%
    IPancakeRouter public router;
    address public wbnb;

    event Swept(
        address indexed user,
        address indexed token,
        uint256 amountIn,
        uint256 userReceived,
        uint256 feeAmount
    );

    modifier onlyOwner() {
        require(msg.sender == owner, "not owner");
        _;
    }

    constructor(address _router, address _feeRecipient, uint256 _feeBps) {
        owner = msg.sender;
        router = IPancakeRouter(_router);
        wbnb = router.WETH();
        feeRecipient = _feeRecipient;
        feeBps = _feeBps;
    }

    // Bot calls this to sweep one or more dust tokens for a user
    function sweep(address user, address[] calldata tokens) external {
        for (uint256 i = 0; i < tokens.length; i++) {
            _sweepToken(user, tokens[i]);
        }
    }

    function _sweepToken(address user, address token) internal {
        IERC20 erc20 = IERC20(token);

        uint256 allowance = erc20.allowance(user, address(this));
        if (allowance == 0) return;

        uint256 balance = erc20.balanceOf(user);
        uint256 amount = allowance < balance ? allowance : balance;
        if (amount == 0) return;

        if (!erc20.transferFrom(user, address(this), amount)) return;

        erc20.approve(address(router), amount);

        address[] memory path = new address[](2);
        path[0] = token;
        path[1] = wbnb;

        uint256 bnbBefore = address(this).balance;

        try router.swapExactTokensForETHSupportingFeeOnTransferTokens(
            amount,
            0,
            path,
            address(this),
            block.timestamp + 300
        ) {
            uint256 received = address(this).balance - bnbBefore;
            if (received == 0) return;

            uint256 fee = (received * feeBps) / 10000;
            uint256 userAmount = received - fee;

            if (fee > 0) {
                (bool s1, ) = feeRecipient.call{value: fee}("");
                require(s1, "fee transfer failed");
            }
            if (userAmount > 0) {
                (bool s2, ) = user.call{value: userAmount}("");
                require(s2, "user transfer failed");
            }

            emit Swept(user, token, amount, userAmount, fee);
        } catch {
            // swap failed (no liquidity etc.), return tokens to user
            erc20.transfer(user, amount);
        }
    }

    function setFeeRecipient(address _feeRecipient) external onlyOwner {
        feeRecipient = _feeRecipient;
    }

    function setFeeBps(uint256 _feeBps) external onlyOwner {
        require(_feeBps <= 3000, "max 30%");
        feeBps = _feeBps;
    }

    receive() external payable {}
}
