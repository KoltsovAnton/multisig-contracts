// use modifiers onlyowner (just own owned) or onlymanyowners(hash), whereby the same hash must be provided by
// some number (specified in constructor) of the set of owners (specified in the constructor, modifiable) before the
// interior is executed.

pragma solidity 0.4.25;

contract multiOwned {
    // FIELDS

    // the number of owners that must confirm the same operation before it is run.
    uint public m_required;
    // pointer used to find a free slot in m_owners
    uint public m_numOwners;

    // list of owners
    uint[256] m_owners;
    uint constant c_maxOwners = 250;
    // index on the list of owners to allow reverse lookup
    mapping(uint => uint) m_ownerIndex;
    // the ongoing operations.
    mapping(bytes32 => PendingState) m_pending;
    bytes32[] m_pendingIndex;

    // TYPES

    // struct for the status of a pending operation.
    struct PendingState {
        uint yetNeeded;
        uint ownersDone;
        uint index;
    }

    // EVENTS

    // this contract only has six types of events: it can accept a confirmation, in which case
    // we record owner and operation (hash) alongside it.
    event Confirmation(address owner, bytes32 operation);
    event Revoke(address owner, bytes32 operation);
    // some others are in the case of an owner changing.
    event OwnerChanged(address oldOwner, address newOwner);
    event OwnerAdded(address newOwner);
    event OwnerRemoved(address oldOwner);
    // the last one is emitted if the required signatures change
    event RequirementChanged(uint newRequirement);

    // MODIFIERS

    // simple single-sig function modifier.
    modifier onlyOwner {
        require(isOwner(msg.sender));
        _;
    }
    // multi-sig function modifier: the operation must have an intrinsic hash in order
    // that later attempts can be realised as the same underlying operation and
    // thus count as confirmations.
    modifier onlyManyOwners(bytes32 _operation) {
        if(confirmAndCheck(_operation, msg.sender))
            _;
    }

    // METHODS

    // constructor is given number of sigs required to do protected "onlymanyowners" transactions
    // as well as the selection of addresses capable of confirming them.
    constructor(address[] _owners, uint _required) public {
        m_numOwners = _owners.length + 1;
        m_owners[1] = uint(msg.sender);
        m_ownerIndex[uint(msg.sender)] = 1;
        for (uint i = 0; i < _owners.length; ++i)
        {
            m_owners[2 + i] = uint(_owners[i]);
            m_ownerIndex[uint(_owners[i])] = 2 + i;
        }
        m_required = _required;
    }

    // Revokes a prior confirmation of the given operation
    function revoke(bytes32 _operation) external {
        uint ownerIndex = m_ownerIndex[uint(msg.sender)];
        // make sure they're an owner
        if (ownerIndex == 0) return;
        uint ownerIndexBit = 2**ownerIndex;
        PendingState storage pending = m_pending[_operation];
        if (pending.ownersDone & ownerIndexBit > 0) {
            pending.yetNeeded++;
            pending.ownersDone -= ownerIndexBit;
            emit Revoke(msg.sender, _operation);
        }
    }

    // Replaces an owner `_from` with another `_to`.
    function changeOwner(address _from, address _to) onlyManyOwners(keccak256(msg.data)) external {
        if (isOwner(_to)) return;
        uint ownerIndex = m_ownerIndex[uint(_from)];
        if (ownerIndex == 0) return;

        clearPending();
        m_owners[ownerIndex] = uint(_to);
        m_ownerIndex[uint(_from)] = 0;
        m_ownerIndex[uint(_to)] = ownerIndex;
        emit OwnerChanged(_from, _to);
    }


    function addOwner(address _owner) onlyManyOwners(keccak256(msg.data)) external {
        if (isOwner(_owner)) return;

        clearPending();
        if (m_numOwners >= c_maxOwners)
            reorganizeOwners();
        if (m_numOwners >= c_maxOwners)
            return;
        m_numOwners++;
        m_owners[m_numOwners] = uint(_owner);
        m_ownerIndex[uint(_owner)] = m_numOwners;
        emit OwnerAdded(_owner);
    }


    function removeOwner(address _owner) onlyManyOwners(keccak256(msg.data)) external {
        uint ownerIndex = m_ownerIndex[uint(_owner)];
        if (ownerIndex == 0) return;
        if (m_required > m_numOwners - 1) return;

        m_owners[ownerIndex] = 0;
        m_ownerIndex[uint(_owner)] = 0;
        clearPending();
        reorganizeOwners(); //make sure m_numOwner is equal to the number of owners and always points to the optimal free slot
        emit OwnerRemoved(_owner);
    }

    function changeRequirement(uint _newRequired) onlyManyOwners(keccak256(msg.data)) external {
        if (_newRequired > m_numOwners) return;
        m_required = _newRequired;
        clearPending();
        emit RequirementChanged(_newRequired);
    }

    // Gets an owner by 0-indexed position (using numOwners as the count)
    function getOwner(uint ownerIndex) external view returns (address) {
        return address(m_owners[ownerIndex + 1]);
    }


    function isOwner(address _addr) public view returns (bool) {
        return m_ownerIndex[uint(_addr)] > 0;
    }


    function hasConfirmed(bytes32 _operation, address _owner) public view returns (bool) {
        PendingState storage pending = m_pending[_operation];
        uint ownerIndex = m_ownerIndex[uint(_owner)];

        // make sure they're an owner
        if (ownerIndex == 0) return false;

        // determine the bit to set for this owner.
        uint ownerIndexBit = 2**ownerIndex;
        return !(pending.ownersDone & ownerIndexBit == 0);
    }

    // INTERNAL METHODS

    function confirmAndCheck(bytes32 _operation, address _user) internal returns (bool) {
        // determine what index the present sender is:
        uint ownerIndex = m_ownerIndex[uint(_user)];
        // make sure they're an owner
        if (ownerIndex == 0) return;

        PendingState storage pending = m_pending[_operation];
        // if we're not yet working on this operation, switch over and reset the confirmation status.
        if (pending.yetNeeded == 0) {
            // reset count of confirmations needed.
            pending.yetNeeded = m_required;
            // reset which owners have confirmed (none) - set our bitmap to 0.
            pending.ownersDone = 0;
            pending.index = m_pendingIndex.length++;
            m_pendingIndex[pending.index] = _operation;
        }
        // determine the bit to set for this owner.
        uint ownerIndexBit = 2**ownerIndex;
        // make sure we (the message sender) haven't confirmed this operation previously.
        if (pending.ownersDone & ownerIndexBit == 0) {
            emit Confirmation(_user, _operation);
            // ok - check if count is enough to go ahead.
            if (pending.yetNeeded <= 1) {
                // enough confirmations: reset and run interior.
                delete m_pendingIndex[m_pending[_operation].index];
                delete m_pending[_operation];
                return true;
            }
            else
            {
                // not enough: record that this owner in particular confirmed.
                pending.yetNeeded--;
                pending.ownersDone |= ownerIndexBit;
            }
        }
    }


    function reorganizeOwners() private {
        uint free = 1;
        while (free < m_numOwners)
        {
            while (free < m_numOwners && m_owners[free] != 0) free++;
            while (m_numOwners > 1 && m_owners[m_numOwners] == 0) m_numOwners--;
            if (free < m_numOwners && m_owners[m_numOwners] != 0 && m_owners[free] == 0)
            {
                m_owners[free] = m_owners[m_numOwners];
                m_ownerIndex[m_owners[free]] = free;
                m_owners[m_numOwners] = 0;
            }
        }
    }


    function clearPending() internal {
        uint length = m_pendingIndex.length;
        for (uint i = 0; i < length; ++i)
            if (m_pendingIndex[i] != 0)
                delete m_pending[m_pendingIndex[i]];
        delete m_pendingIndex;
    }
}

// inheritable "property" contract that enables methods to be protected by placing a linear limit (specifiable)
// on a particular resource per calendar day. is multiOwned to allow the limit to be altered. resource that method
// uses is specified in the modifier.
contract dayLimit is multiOwned {
    // FIELDS

    uint public m_dailyLimit;
    uint public m_spentToday;
    uint public m_lastDay;

    // MODIFIERS

    // simple modifier for daily limit.
    modifier limitedDaily(uint _value) {
        require(underLimit(_value));
        _;
    }

    // METHODS

    // constructor - stores initial daily limit and records the present day's index.
    constructor(uint _limit) public {
        m_dailyLimit = _limit;
        m_lastDay = today();
    }

    // (re)sets the daily limit. needs many of the owners to confirm. doesn't alter the amount already spent today.
    function setDailyLimit(uint _newLimit) onlyManyOwners(keccak256(msg.data)) external {
        m_dailyLimit = _newLimit;
    }

    // resets the amount already spent today. needs many of the owners to confirm.
    function resetSpentToday() onlyManyOwners(keccak256(msg.data)) external {
        m_spentToday = 0;
    }

    // INTERNAL METHODS

    // checks to see if there is at least `_value` left from the daily limit today. if there is, subtracts it and
    // returns true. otherwise just returns false.
    function underLimit(uint _value) internal onlyOwner returns (bool) {
        // reset the spend limit if we're on a different day to last time.
        if (today() > m_lastDay) {
            m_spentToday = 0;
            m_lastDay = today();
        }
        // check to see if there's enough left - if so, subtract and return true.
        // overflow protection                    // dailyLimit check
        if (m_spentToday + _value >= m_spentToday && m_spentToday + _value <= m_dailyLimit) {
            m_spentToday += _value;
            return true;
        }
        return false;
    }

    // determines today's index.
    function today() private constant returns (uint) { return now / 1 days; }

}

// interface contract for multiSig proxy contracts; see below for docs.
interface multiSig {

    // EVENTS

    // logged events:
    // Funds has arrived into the wallet (record how much).
    event Deposit(address _from, uint value);
    // Single transaction going out of the wallet (record who signed for it, how much, and to whom it's going).
    event SingleTransact(address owner, uint value, address to, bytes data);
    // Multi-sig transaction going out of the wallet (record who signed for it last, the operation hash, how much, and to whom it's going).
    event MultiTransact(address owner, bytes32 operation, uint value, address to, bytes data);
    // Confirmation still needed for a transaction.
    event ConfirmationNeeded(bytes32 operation, address initiator, uint value, address to, bytes data);

    // FUNCTIONS
    function changeOwner(address _from, address _to) external;
    function execute(address _to, uint _value, bytes _data) external returns (bytes32);
    function confirm(bytes32 _h) external returns (bool);
}


interface Management {
    function addUser(uint subscriptionPlan) external returns (bool);
    function isPaid(address _user) external view returns (bool);
    function makePayment() external payable returns (bool);
    function getPriceForUser(address _user) external view returns (uint);
}

// usage:
// bytes32 h = Wallet(w).from(oneOwner).execute(to, value, data);
// Wallet(w).from(anotherOwner).confirm(h);
contract Wallet is multiSig, multiOwned, dayLimit {
    // FIELDS

//    Management public managementContract;
    address public signer;

    // pending transactions we have at present.
    mapping (bytes32 => Transaction) m_txs;

    uint private startGas;
    uint private gasUsed;
    uint private price;
    bytes32 private hash;
    address private user1;
    address private user2;


    // TYPES

    // Transaction structure to remember details of transaction lest it need be saved for a later call.
    struct Transaction {
        address to;
        uint value;
        bytes data;
    }

    // METHODS

    // constructor - just pass on the owner array to the multiOwned and
    // the limit to dayLimit
    constructor(address[] _owners, uint _required, uint _dayLimit, /* address _management, uint _subscriptionPlan, */ address _signer) public
    multiOwned(_owners, _required) dayLimit(_dayLimit)
    {
//        require(_management != address(0));
        require(_signer != address(0));

//        managementContract = Management(_management);
//        require(managementContract.addUser(_subscriptionPlan));

        signer = _signer;
    }

    // kills the contract sending everything to `_to`.
    //!!!WITHDRAW ALL TOKENS BEFORE KILL!!!
    function kill(address _to) onlyManyOwners(keccak256(msg.data)) external {
        selfdestruct(_to);
    }

    // gets called when no other function matches
    function() public payable {
        //        if (msg.value > 0)
        //            emit Deposit(msg.sender, msg.value);
    }

    // Outside-visible transact entry point. Executes transaction immediately if below daily spend limit.
    // If not, goes into multisig process. We provide a hash on return to allow the sender to provide
    // shortcuts for the other confirmations (allowing them to avoid replicating the _to, _value
    // and _data arguments). They still get the option of using them if they want, anyways.
    function execute(address _to, uint _value, bytes _data) external onlyOwner returns (bytes32 _r) {
//        if (!managementContract.isPaid(this)) {
//            price = managementContract.getPriceForUser(this);
//            require(managementContract.makePayment.value(price)());
//        }

        // first, take the opportunity to check that we're under the daily limit.
        if (underLimit(_value) && _data.length == 0) {
            emit SingleTransact(msg.sender, _value, _to, _data);
            // yes - just execute the call.
            require(_to.call.value(_value)(_data));
            return 0;
        }
        // determine our operation hash.
        _r = keccak256(abi.encodePacked(msg.data, block.number));
        if (!confirm(_r) && m_txs[_r].to == 0) {
            m_txs[_r].to = _to;
            m_txs[_r].value = _value;
            m_txs[_r].data = _data;
            emit ConfirmationNeeded(_r, msg.sender, _value, _to, _data);
        }
    }

    // confirm a transaction through just the hash. we use the previous transactions map, m_txs, in order
    // to determine the body of the transaction from the hash provided.
    function confirm(bytes32 _h) onlyManyOwners(_h) public returns (bool) {
        if (m_txs[_h].to != 0) {
            startGas = gasleft();
            gasUsed = 40000;

            require(m_txs[_h].to.call.value(m_txs[_h].value)(m_txs[_h].data));
            emit MultiTransact(msg.sender, _h, m_txs[_h].value, m_txs[_h].to, m_txs[_h].data);
            delete m_txs[_h];

            gasUsed = gasUsed + (startGas - gasleft());
            signer.transfer(gasUsed * tx.gasprice);
            return true;
        }
    }



    function executeAndConfirm(address _to, uint _value, bytes _data, uint8[] v, bytes32[] r, bytes32[] s) external onlyOwner returns (bool)
    {
        startGas = gasleft();
        gasUsed = 23000;

//        if (!managementContract.isPaid(this)) {
//            price = managementContract.getPriceForUser(this);
//            require(managementContract.makePayment.value(price)());
//        }

        // first, take the opportunity to check that we're under the daily limit.
        if (underLimit(_value) && _data.length == 0) {
            emit SingleTransact(msg.sender, _value, _to, _data);
            // yes - just execute the call.
            require(_to.call.value(_value)(_data));
            return true;
        }

        // determine our operation hash.
//        bytes32 _r = keccak256(abi.encodePacked(msg.data, block.number));

        hash = sha256(abi.encodePacked(_to, _value, _data));
        user1 = ecrecover(keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", hash)), v[0], r[0], s[0]);
        user2 = ecrecover(keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", hash)), v[1], r[1], s[1]);


        require(isOwner(msg.sender));
        require(isOwner(user1));
        require(isOwner(user2));

//        confirmAndCheck(_r, msg.sender);
//        confirmAndCheck(_r, user1);
//        require(confirmAndCheck(_r, user2));

        require(_to.call.value(_value)(_data));
        emit MultiTransact(msg.sender, 0, _value, _to, _data);

        gasUsed = gasUsed + (startGas - gasleft());
        signer.transfer(gasUsed * tx.gasprice);
        return true;
    }



//    function setManagementContract(address _management) onlyManyOwners(keccak256(msg.data)) public returns (bool) {
//        require(_management != address(0));
//        managementContract = Management(_management);
//    }

    // INTERNAL METHODS

    function clearPending() internal {
        uint length = m_pendingIndex.length;
        for (uint i = 0; i < length; ++i)
            delete m_txs[m_pendingIndex[i]];
        super.clearPending();
    }


}



contract WalletFactory {
    address[] public wallets;

    event NewWallet(address indexed owner, address indexed owner2, address indexed owner3, address wallet);


    function createWallet(address[] _owners, uint _required, uint _dayLimit, /* address _management, uint _subscriptionPlan,*/ address _signer)
    public returns (Wallet) {
        Wallet newWallet = new Wallet(
            _owners, _required, _dayLimit, /* _management, _subscriptionPlan, */ _signer
        );

        wallets.push(address(newWallet));
        emit NewWallet(_owners[0], _owners[1], _owners[2], address(newWallet));
        return newWallet;
    }

    function walletsCount() public view returns (uint) {
        return wallets.length;
    }
}
