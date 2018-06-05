pragma solidity ^0.4.24;

import "../kernel/Module.sol";
import "./ProjectControllerStorage.sol";

contract ProjectController is Module {
    // events
    event ProjectRegistered(
        address indexed sender,
        bytes32 namespace,
        address indexed owner,
        address indexed tokenAddress
    );
    event ProjectUnregistered(address indexed sender, bytes32 namespace);
    event ProjectStateSet(address indexed sender, bytes32 namespace, uint projectState);
    event ProjectControllerStoreSet(
        address indexed sender,
        bytes32 projectControllerCI,
        bytes32 projectControllerStorageCI,
        address indexed store);

    /*
      1. Can only add state in order but before LENGTH
      2. Do not delete or rearrange states
      3. If you want to depreciate a state, add comment like
         // @depreciated
         SOME_STATE
    */
    enum ProjectState {
        NotExist,
        AppSubmitted,
        AppAccepted,
        TokenSale,
        Milestone,
        Complete,
        LENGTH
    }

    address constant ZERO_ADDRESS = address(0x0);
    bytes32 constant ZERO_BYTES32 = keccak256("-1");
    string constant OWNER = "owner";
    string constant TOKEN_ADDRESS = "tokenAddress";
    string constant PROJECT_STATE = "projectState";
    string constant NAMESPACE = "namespace";

    ProjectControllerStorage private projectControllerStore;

    constructor (address kernelAddr) Module(kernelAddr) public {
        CI = keccak256("ProjectController");
    }

    /**
    * Register a project
    *
    * @param namespace namespace of a project
    * @param owner the owner address for the project
    * @param tokenAddress the token address for the project
    */
    function registerProject(bytes32 namespace, address owner, address tokenAddress)
        external
        connected
    {
        bool existing;
        (existing,) = isExisting(namespace);
        require(!existing);

        projectControllerStore.setAddress(keccak256(namespace, OWNER), owner);
        projectControllerStore.setAddress(keccak256(namespace, TOKEN_ADDRESS), tokenAddress);
        projectControllerStore.setUint(
            keccak256(namespace, PROJECT_STATE),
            uint256(ProjectState.AppSubmitted)
        );
        projectControllerStore.setBytes32(keccak256(owner, NAMESPACE), namespace);

        emit ProjectRegistered(msg.sender, namespace, owner, tokenAddress);
    }

    /**
    * Unregister a project
    *
    * @param namespace namespace of a project
    */
    function unregisterProject(bytes32 namespace) external connected {
        bool existing;
        address owner;
        (existing, owner) = isExisting(namespace);
        require(existing);

        projectControllerStore.setAddress(keccak256(namespace, OWNER), ZERO_ADDRESS);
        projectControllerStore.setAddress(keccak256(namespace, TOKEN_ADDRESS), ZERO_ADDRESS);
        projectControllerStore.setUint(
            keccak256(namespace, PROJECT_STATE),
            uint256(ProjectState.NotExist)
        );
        projectControllerStore.setBytes32(keccak256(owner, NAMESPACE), ZERO_BYTES32);

        emit ProjectUnregistered(msg.sender, namespace);
    }

    /**
    * Set the state of a project
    *
    * @param namespace namespace of a project
    * @param projectState state of the project
    */
    function setState(bytes32 namespace, uint projectState) external connected {
        bool existing;
        address owner;
        (existing, owner) = isExisting(namespace);
        require(existing);
        require(projectState >= 0 && projectState <= uint(ProjectState.LENGTH));

        projectControllerStore.setUint(keccak256(namespace, PROJECT_STATE), uint256(projectState));

        emit ProjectStateSet(msg.sender, namespace, projectState);
    }

    /**
    * Bind with a storage contract
    * Create a new storage contract if _store == 0x0
    *
    * @param store the address of a storage contract
    */
    function setStorage(address store) public connected {
        super.setStorage(store);
        projectControllerStore = ProjectControllerStorage(storeAddr);

        emit ProjectControllerStoreSet(msg.sender, CI, projectControllerStore.CI(), store);
    }

    /**
    * Return the namespace belongs to an owner
    *
    * @param owner address for an owner
    */
    function getNamespace(address owner) public view returns (bytes32) {
        return projectControllerStore.getBytes32(keccak256(owner, NAMESPACE));
    }

    /**
    * Return the token address belongs to a project
    *
    * @param namespace namespace of a project
    */
    function getTokenAddress(bytes32 namespace) public view returns (address) {
        bool existing;
        (existing,) = isExisting(namespace);
        require(existing);

        return projectControllerStore.getAddress(keccak256(namespace, TOKEN_ADDRESS));
    }

    /**
    * Return the project state for a project
    *
    * @param namespace namespace of a project
    */
    function getProjectState(bytes32 namespace) public view returns (uint) {
        bool existing;
        (existing,) = isExisting(namespace);
        require(existing);

        return uint(projectControllerStore.getUint(keccak256(namespace, PROJECT_STATE)));
    }

    /**
    * Verify whether an onwer address belongs to a project
    *
    * @param namespace namespace of a project
    * @param owner address for an owner
    */
    function verifyOwner(bytes32 namespace, address owner) public view returns (bool) {
        require(owner != ZERO_ADDRESS);
        return projectControllerStore.getAddress(keccak256(namespace, OWNER)) == owner;
    }

    /**
    * Return true and return owner address if a project exists
    *
    * @param namespace namespace of a project
    */
    function isExisting(bytes32 namespace) internal view returns (bool, address) {
        address owner = projectControllerStore.getAddress(keccak256(namespace, OWNER));
        return owner != ZERO_ADDRESS ? (true, owner) : (false, ZERO_ADDRESS);
    }
}