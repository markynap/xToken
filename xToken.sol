pragma solidity 0.8.4;
//SPDX-License-Identifier: MIT

import "./Address.sol";
import "./SafeMath.sol";
import "./IXToken.sol";
import "./IUniswapV2Router02.sol";
import "./ReentrantGuard.sol";

/**
 * Contract: xToken
 * Developed By: Markymark (DeFiMark / MoonMark)
 *
 * Tax Exempt (or Extra) Token that is Pegged 1:1 to a Native Asset
 * Can Be Used For Tax-Exemptions, Low Gas Transfers, Or anything else
 *
 */
contract xToken is IXToken, ReentrancyGuard {

    using SafeMath for uint256;
    using SafeMath for uint8;
    using Address for address;

    // Native Token Contract Address
    address public immutable _native;
    // To Collect Peg In/Out Fees
    address public _feeCollector;
    // Liquidity Provider For xToken Pairings
    address public _liquidityProvider;
    // contract owner
    address public _owner;
    modifier onlyOwner(){require(msg.sender == _owner, 'Only Owner Function'); _;}
    // PCS Router For Auto Purchase->Convert on BNB Received
    IUniswapV2Router02 _router;
    // BNB -> Native
    address[] path;
    // allow Self Minting
    bool _allowSelfMinting;
    // token data
    string _name;
    string _symbol;
    uint8 immutable _decimals;
    // 0 Total Supply
    uint256 _totalSupply = 0;
    // transfer tax
    uint256 public _transferDenom;
    uint256 public _bridgeFee;
    uint256 public _purchaseFee;
    uint256 public constant _bridgeFeeDenom = 10**5;
    // balances
    mapping (address => uint256) _balances;
    mapping (address => mapping (address => uint256)) _allowances;
    // blacklist liquidity pools that are not xTokens
    mapping (address => bool) blacklistedLP;

    // Create xToken
    constructor ( address native, string memory tName, string memory tSymbol, uint8 nativeDecimals, address feeCollector, address liquidityProvider
    ) {
        _name = tName;
        _symbol = tSymbol;
        _decimals = nativeDecimals;
        _native = native;
        _feeCollector = feeCollector;
        _liquidityProvider = liquidityProvider;
        _router = IUniswapV2Router02(0x10ED43C718714eb63d5aA57B78B54704E256024E);
        path = new address[](2);
        path[0] = _router.WETH();
        path[1] = native;
        _allowSelfMinting = true;
        _transferDenom = 400;
        _bridgeFee = 200;
        _purchaseFee = 20;
        _owner = msg.sender;
    }
    // basic IERC20 Functions
    function totalSupply() external view override returns (uint256) { return _totalSupply; }
    function balanceOf(address account) public view override returns (uint256) { return _balances[account]; }
    function allowance(address holder, address spender) external view override returns (uint256) { return _allowances[holder][spender]; }

    function name() public view returns (string memory) {
        return _name;
    }

    function symbol() public view returns (string memory) {
        return _symbol;
    }

    function decimals() public view override returns (uint8) {
        return _decimals;
    }

    function approve(address spender, uint256 amount) public override returns (bool) {
        _allowances[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    /** Transfer Function */
    function transfer(address recipient, uint256 amount) external override returns (bool) {
        return _transferFrom(msg.sender, recipient, amount);
    }
    /** Transfer Function */
    function transferFrom(address sender, address recipient, uint256 amount) external override returns (bool) {
        _allowances[sender][msg.sender] = _allowances[sender][msg.sender].sub(amount, "Insufficient Allowance");
        return _transferFrom(sender, recipient, amount);
    }

    /** Internal Transfer */
    function _transferFrom(address sender, address recipient, uint256 amount) internal returns (bool) {
        // make standard checks
        require(recipient != address(0), "BEP20: transfer to the zero address");
        require(amount > 0, "Transfer amount must be greater than zero");
        require(!blacklistedLP[recipient] && !blacklistedLP[sender], 'Blacklisted Liquidity Pool Detected');
        // subtract from sender
        _balances[sender] = _balances[sender].sub(amount, "Insufficient Balance");
        // take a tax
        uint256 tax = amount.div(_transferDenom);
        // Add to Fee Collector
        _balances[_liquidityProvider] = _balances[_liquidityProvider].add(tax);
        // receiver gets amount sub tax
        amount = amount.sub(tax);
        // give amount to receiver
        _balances[recipient] = _balances[recipient].add(amount);
        // Transfer Event
        emit Transfer(sender, recipient, amount);
        emit Transfer(sender, _liquidityProvider, tax);
        return true;
    }
    
    
    ////////////////////////////////////
    //////    PUBLIC FUNCTIONS    //////
    ////////////////////////////////////
    


    /** Creates xTokens based on how many Native received */
    function mintXToken(uint256 nNative) external override nonReentrant returns(bool) {
        return _mintXToken(nNative);
    }
    
    /** Destroys xTokens based on how many it is sending back */
    function redeemNative(uint256 amount) external override nonReentrant returns(bool) {
        return _redeemNative(amount);
    }
    
    /** Swaps xToken For xToken if pairing on PCS exists between them */
    function swapTokenForToken(address tokenToReceive, uint256 amountStartingToken) external nonReentrant returns (bool) {
        return _swapTokenForToken(tokenToReceive, amountStartingToken, msg.sender);
    }
    
    
    
    ////////////////////////////////////
    //////   INTERNAL FUNCTIONS   //////
    ////////////////////////////////////
    
    
    /** Creates xTokens based on how many Native received */
    function _mintXToken(uint256 nNative) private returns(bool) {
        // native balance of sender
        uint256 bal = IERC20(_native).balanceOf(msg.sender);
        require(bal > 0 && nNative <= bal, 'Insufficient Balance');
        // balance before transfer
        uint256 balBefore = IERC20(_native).balanceOf(address(this));
        // move tokens into contract
        bool success = IERC20(_native).transferFrom(msg.sender, address(this), nNative);
        // balance after transfer
        uint256 received = IERC20(_native).balanceOf(address(this)).sub(balBefore);
        require(received <= nNative && received > 0 && success, 'Failure In Transfer Evaluation');
        // allocate fee to go toward dynamic liquidity
        uint256 taxAmount = calculateBridgeFee(received);
        // how much should we send without the tax
        uint256 amountToSend = received.sub(taxAmount);
        // add xToken to receiver's wallet
        _balances[msg.sender] = _balances[msg.sender].add(amountToSend);
        // add tax to the Liquidity Provider
        _balances[_feeCollector] = _balances[_feeCollector].add(taxAmount);
        // Increase total supply
        _totalSupply = _totalSupply.add(received);
        // make sure this won't break the 1:1
        require(_totalSupply <= IERC20(_native).balanceOf(address(this)), 'This Transaction Would Break the 1:1 Ratio');
        // tell the blockchain
        emit Transfer(address(this), msg.sender, amountToSend);
        emit Transfer(address(this), _feeCollector, taxAmount);
        return true;
    }
    
    /** Destroys xTokens based on how many it is sending back */
    function _redeemNative(uint256 amount) private returns(bool) {
        // check balance of Native
        uint256 nativeBal = IERC20(_native).balanceOf(address(this));
        // make sure there is enough native asset to transfer
        require(nativeBal >= amount && nativeBal > 0 && amount <= _balances[msg.sender] && _balances[msg.sender] > 0, 'Insufficient Balance');
        amount = amount == 0 ? _balances[msg.sender] : amount;
        // allocate bridge fee to go toward dynamic liquidity
        uint256 taxAmount = calculateBridgeFee(amount);
        // how much should we send without the tax
        uint256 amountToBurn = amount.sub(taxAmount);
        // subtract full amount from sender
        _balances[msg.sender] = _balances[msg.sender].sub(amount, 'Insufficient Sender Balance');
        // add xToken to dynamic liquidity receiver
        _balances[_feeCollector] = _balances[_feeCollector].add(taxAmount);
        // if successful, remove tokens from supply
        _totalSupply = _totalSupply.sub(amountToBurn, 'total supply cannot be negative');
        // transfer Native from this contract to destroyer
        bool success = IERC20(_native).transfer(msg.sender, amountToBurn);
        // check if transfer succeeded
        require(success, 'Native Transfer Failed');
        // enforce 1:1
        require(_totalSupply <= IERC20(_native).balanceOf(address(this)), 'This tx would break the 1:1 ratio');
        // Transfer from seller to address
        emit Transfer(msg.sender, address(this), amount);
        if (taxAmount > 0) emit Transfer(address(this), _feeCollector, taxAmount);
        return true;
    }
    
    /** Swaps xToken For xToken if pairing on PCS exists between them */
    function _swapTokenForToken(address tokenToReceive, uint256 amountStartingToken, address recipient) private returns (bool) {
        // check cases
        require(_balances[recipient] >= amountStartingToken && _balances[recipient] > 0, 'Insufficient Balance');
        // if zero use full balance 
        amountStartingToken = amountStartingToken == 0 ? _balances[recipient] : amountStartingToken;
        // re-allocate balances before swap initiates
        _balances[recipient] = _balances[recipient].sub(amountStartingToken, 'Insufficient Balance Subtraction Overflow');
        _balances[address(this)] = _balances[address(this)].add(amountStartingToken);
        // path from this -> desired token
        address[] memory tokenPath = new address[](2);
        tokenPath[0] = address(this);
        tokenPath[1] = tokenToReceive;
        // approve router to move tokens
        _allowances[address(this)][address(_router)] = amountStartingToken;
        // make the swap
        try _router.swapExactTokensForTokensSupportingFeeOnTransferTokens(
            amountStartingToken,
            0,
            tokenPath,
            recipient, // give to recipient
            block.timestamp.add(30)
        ) {} catch {revert('Error On Token Swap');}
        return true;
    }
    
    /** Buys Native, Returns Amount Received From Purchase */
    function buyToken() private returns (uint256) {
        // Match Native Purchase Fee
        uint256 taxAmount = msg.value.mul(_purchaseFee).div(10**3);
        uint256 swapAmount = msg.value.sub(taxAmount);
        // balance before swap
        uint256 balBefore = IERC20(_native).balanceOf(address(this));
        // make swap
        _router.swapExactETHForTokens{value:swapAmount}(
            0,
            path,
            address(this),
            block.timestamp.add(30)
        );
        // collect fee
        (bool succ,) = payable(_feeCollector).call{value: taxAmount}("");
        require(succ, 'Error On Fee Collection');
        // return amount purchased
        return IERC20(_native).balanceOf(address(this)).sub(balBefore);
    }
    
    /** Private Function To Mint xTokens on BNB Received */
    function _selfMintXToken() private returns(bool) {
        // purchase Native
        uint256 received = buyToken();
        // received from purchase
        require(received > 0, 'Zero Native Received');
        // allocate fee to go toward dynamic liquidity
        uint256 taxAmount = calculateBridgeFee(received);
        // how much should we send without the tax
        uint256 amountToSend = received.sub(taxAmount);
        // add xToken to receiver's wallet
        _balances[msg.sender] = _balances[msg.sender].add(amountToSend);
        // add tax to the Liquidity Provider
        _balances[_feeCollector] = _balances[_feeCollector].add(taxAmount);
        // Increase total supply
        _totalSupply = _totalSupply.add(received);
        // make sure this won't break the 1:1
        require(_totalSupply <= IERC20(_native).balanceOf(address(this)), 'This Transaction Would Break the 1:1 Ratio');
        // tell the blockchain
        emit Transfer(address(this), msg.sender, amountToSend);
        emit Transfer(address(this), _feeCollector, taxAmount);
        return true;
    }
    
    
    ////////////////////////////////////
    //////     OWNER FUNCTIONS    //////
    ////////////////////////////////////



    /** Withdraw Tokens that are not native token that were mistakingly sent to this address */
    function withdrawTheMistakesOfOthers(address tokenAddress, uint256 nTokens) external onlyOwner {
        require(tokenAddress != _native, 'CANNOT WITHDRAW NATIVE');
        nTokens = nTokens == 0 ? IERC20(tokenAddress).balanceOf(address(this)) : nTokens;
        IERC20(tokenAddress).transfer(msg.sender, nTokens);
        emit WithdrawTheMistakesOfOthers(tokenAddress, nTokens);
    }
    
    /** Enforce One to One Ratio In Event Tokens Are Incorrectly Sent To Contract */
    function enforceOneToOne() external onlyOwner {
        // check balance of Native
        uint256 nativeBal = IERC20(_native).balanceOf(address(this));
        // has Native been sent to xToken by mistake
        if (nativeBal > _totalSupply) {
            // send excess to liquidity provider
            IERC20(_native).transfer(_feeCollector, nativeBal.sub(_totalSupply));
        }
    }
    
    /** Excludes A Liquidity Pool From Exchanging This xToken */
    function blacklistLiquidityPool(address lpAddress, bool excluded) external onlyOwner {
        require(lpAddress != address(this), 'Cannot Exclude xToken');
        blacklistedLP[lpAddress] = excluded;
        emit BlacklistedLiquidityPool(lpAddress, excluded);
    }

    /** Incase Pancakeswap Upgrades To V3 */
    function updateFeeCollectorAddress(address newFeeCollector) external onlyOwner {
        _feeCollector = newFeeCollector;
        emit UpdatedFeeCollector(newFeeCollector);
    }
    
    /** Incase Pancakeswap Upgrades To V3 */
    function updateLiquidityProviderAddress(address newLiquidityProvider) external onlyOwner {
        _liquidityProvider = newLiquidityProvider;
        emit UpdatedLiquidityProvider(newLiquidityProvider);
    }
    
    /** Upgrades The Pancakeswap Router Used To Purchase Native on BNB Received */
    function updatePancakeswapRouterAddress(address newPCSRouter) external onlyOwner {
        _router = IUniswapV2Router02(newPCSRouter);
        path[0] = _router.WETH();
        emit UpdatedPancakeswapRouter(newPCSRouter);
    }
    
    /** Transfers Ownership To New Address */
    function transferOwnership(address newOwner) external onlyOwner {
        _owner = newOwner;
        emit TransferOwnership(newOwner);
    }
    
    /** Updates The Fee Taken Between Token Transfers */
    function setTransferDenominator(uint256 newDenom) external onlyOwner {
        require(newDenom >= 5, 'Transfer Fee Too High');
        _transferDenom = newDenom;
        emit UpdatedTransferDenominator(newDenom);
    }
    
    /** Updates The Native Purchase Fee */
    function setPurchaseFee(uint256 newPurchaseFee) external onlyOwner {
        require(newPurchaseFee <= 300, 'Fee Too High');
        _purchaseFee = newPurchaseFee;
        emit UpdatedPurchaseFee(newPurchaseFee);
    }
    
    /** Allows BNB Received To Auto Buy+Bridge Native into xToken */
    function setAllowSelfMinting(bool allow) external onlyOwner {
        _allowSelfMinting = allow;
        emit UpdatedAllowSelfMinting(allow);
    }
    
    /** Updates The Fee Taken When Minting/Burning xTokens */
    function setBridgeFee(uint256 newBridgeFee) external onlyOwner {
        require(newBridgeFee <= _bridgeFeeDenom.div(4), 'Bridge Fee Too High');
        _bridgeFee = newBridgeFee;
        emit UpdatedBridgeFee(newBridgeFee);
    }
    
    ////////////////////////////////////
    //////     READ FUNCTIONS     //////
    ////////////////////////////////////
    
    /** If LP is Blacklisted */
    function isBlacklisted(address liquidityPool) external view returns(bool) {
        return blacklistedLP[liquidityPool];
    }

    /** Caulcates Bridge Fee Applied When Minting / Redeeming xTokens */
    function calculateBridgeFee(uint256 amount) public view returns (uint256) {
        return amount.mul(_bridgeFee).div(_bridgeFeeDenom);
    }

    /** Returns the Native Token This xToken Is Pegged To */
    function getNativeAddress() external override view returns(address) {
        return _native;
    }
    
    /** Returns the amount of Native Asset in this contract */
    function getNativeBalanceInContract() external view returns(uint256) {
        return IERC20(_native).balanceOf(address(this));
    }
    
    receive() external payable {
        require(_allowSelfMinting, 'Self Minting is Disabled');
        require(_selfMintXToken(), 'Error Minting xTokens From BNB Transfer');
    }

    // EVENTS
    event UpdatedBridgeFee(uint256 newBridgeFee);
    event UpdatedFeeCollector(address newFeeBurner);
    event UpdatedLiquidityProvider(address newProvider);
    event UpdatedPurchaseFee(uint256 newPurchaseFee);
    event UpdatedAllowSelfMinting(bool allow);
    event UpdatedTransferDenominator(uint256 newDenom);
    event UpdatedPancakeswapRouter(address newRouter);
    event BlacklistedLiquidityPool(address LiquidityPool, bool isExcluded);
    event WithdrawTheMistakesOfOthers(address token, uint256 tokenAmount);
    event TransferOwnership(address newOwner);
}
