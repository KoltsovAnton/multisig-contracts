pragma solidity 0.4.25;

contract Ownable {
    mapping(address => bool) owners;
    mapping(address => bool) managers;

    event OwnerAdded(address indexed newOwner);
    event OwnerDeleted(address indexed owner);
    event ManagerAdded(address indexed newOwner);
    event ManagerDeleted(address indexed owner);

    /**
     * @dev The Ownable constructor sets the original `owner` of the contract to the sender
     * account.
     */
    constructor() public {
        owners[msg.sender] = true;
    }

    /**
     * @dev Throws if called by any account other than the owner.
     */
    modifier onlyOwner() {
        require(isOwner(msg.sender));
        _;
    }

    modifier onlyManager() {
        require(isManager(msg.sender));
        _;
    }

    function addOwner(address _newOwner) external onlyOwner {
        require(_newOwner != address(0));
        owners[_newOwner] = true;
        emit OwnerAdded(_newOwner);
    }

    function delOwner(address _owner) external onlyOwner {
        require(owners[_owner]);
        owners[_owner] = false;
        emit OwnerDeleted(_owner);
    }

    function addManager(address _newManager) external onlyOwner {
        require(_newManager != address(0));
        managers[_newManager] = true;
        emit ManagerAdded(_newManager);
    }

    function delManager(address _manager) external onlyOwner {
        require(managers[_manager]);
        managers[_manager] = false;
        emit ManagerDeleted(_manager);
    }

    function isOwner(address _owner) public view returns (bool) {
        return owners[_owner];
    }

    function isManager(address _manager) public view returns (bool) {
        return managers[_manager];
    }

}


contract ERC20 {
    function balanceOf(address who) public view returns (uint256);
    function transfer(address to, uint256 value) public returns (bool);
}


contract Management is Ownable {
    // FIELDS

    mapping (address => User) public users;

    // TYPES

    struct Tariff {
        bool oneTime;
        uint price;
        uint daysCount;
    }

    struct User {
        uint tariff;
        bool paid;
        uint stopDay;
        bool exists;
    }

    mapping (uint => Tariff) public tariffs;
    uint public tariffCount;

    // EVENTS
    event TariffAdded(uint tariffIndex, bool oneTime, uint price, uint daysCount);
    event TariffUpdated(uint tariffIndex, bool oneTime, uint price, uint daysCount);
    event TariffPriceUpdated(uint tariffIndex, uint price);
    event UserAdded(address user, uint tariffIndex);
    event NewPayment(address user, uint value);


    // MODIFIERS


    // METHODS

    constructor() public {

    }


    function() public payable {
        revert();
    }


    function addTariff(bool _oneTime, uint _price, uint _daysCount) onlyOwner public {
        tariffCount++;
        tariffs[tariffCount].oneTime = _oneTime;
        tariffs[tariffCount].price = _price;
        tariffs[tariffCount].daysCount = _daysCount;
        emit TariffAdded(tariffCount, _oneTime, _price, _daysCount);
    }


    function editTariff(uint _tariff, bool _oneTime, uint _price, uint _daysCount) onlyOwner public {
        require(_tariff <= tariffCount);
        tariffs[_tariff].oneTime = _oneTime;
        tariffs[_tariff].price = _price;
        tariffs[_tariff].daysCount = _daysCount;
        emit TariffAdded(_tariff, _oneTime, _price, _daysCount);
    }


    function updateTariffPrice(uint _tariff, uint _price) onlyManager public {
        require(_tariff <= tariffCount);
        tariffs[_tariff].price = _price;
        emit TariffPriceUpdated(_tariff, _price);
    }


    function addUser(uint _tariff) external returns (bool) {
        require(_tariff <= tariffCount);
        users[msg.sender].tariff = _tariff;
        users[msg.sender].exists = true;
        emit UserAdded(msg.sender, _tariff);
        return true;
    }


    function makePayment() external payable returns (bool) {
        require(users[msg.sender].exists);
        require(msg.value >= tariffs[users[msg.sender].tariff].price);

        if (tariffs[users[msg.sender].tariff].oneTime) {
            require(!users[msg.sender].paid);
            users[msg.sender].paid = true;
            emit NewPayment(msg.sender, msg.value);
            return true;
        }

        if (!tariffs[users[msg.sender].tariff].oneTime) {

            if (users[msg.sender].stopDay > now) {
                users[msg.sender].stopDay = users[msg.sender].stopDay + 30 days;
            } else {
                users[msg.sender].stopDay = now + 30 days;
            }
            emit NewPayment(msg.sender, msg.value);
            return true;
        }

    }


    function isPaid(address _user) external view returns (bool) {
        if (tariffs[users[_user].tariff].oneTime && users[_user].paid) {
            return true;
        }
        return users[_user].stopDay >= now;
    }


    function getPriceForUser(address _user) external view returns (uint) {
        return tariffs[users[_user].tariff].price;
    }

    /// @notice This method can be used by the owner to extract mistakenly
    ///  sent tokens to this contract.
    /// @param _token The address of the token contract that you want to recover
    ///  set to 0 in case you want to extract ether.
    function claimTokens(address _token, address _to) external onlyOwner {
        require(_to != address(0));
        if (_token == 0x0) {
            _to.transfer(address(this).balance);
            return;
        }

        ERC20 token = ERC20(_token);
        uint balance = token.balanceOf(this);
        token.transfer(_to, balance);
    }

    // INTERNAL METHODS

}
