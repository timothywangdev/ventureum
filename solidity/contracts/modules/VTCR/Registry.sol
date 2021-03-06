pragma solidity ^0.4.24;

import "openzeppelin-solidity/contracts/math/SafeMath.sol";
import "vetx-token/contracts/VetXToken.sol";

import "../../library/DLLBytes32.sol";

import "./Parameterizer.sol";
import "./Challenge.sol";
import "./PLCRVoting.sol";
import "../Module.sol";
import "../project_controller/ProjectController.sol";


contract Registry is Module {
    using Challenge for Challenge.Data;
    using DLLBytes32 for DLLBytes32.Data;
    using SafeMath for uint;

    // ------
    // EVENTS
    // ------

    event _Application(address indexed applicant, string project, uint deposit);
    event _Challenge(address indexed challenger, string project, uint deposit, uint pollId);
    event _NewProjectWhitelisted(string project);
    event _ApplicationRemoved(string project);
    event _ListingRemoved(string project);
    event _ChallengeFailed(uint challengeId);
    event _ChallengeSucceeded(uint challengeId);
    event _RewardClaimed(address indexed voter, uint challengeId, uint reward);
    event _WithdrawByVentureumTeam(address indexed onwer, uint amount);
    // ------
    // DATA STRUCTURES
    // ------

    struct Listing {
        uint applicationExpiry; // Expiration date of apply stage
        bool whitelisted;       // Indicates registry status
        address owner;          // Owner of Listing
        uint unstakedDeposit;   // Number of unlocked tokens with potential risk if challenged
        uint challengeId;       // Identifier of canonical challenge
        string projectName;     // Project Name
    }

    // ------
    // STATE
    // ------

    // project hash list stored in a DLL
    DLLBytes32.Data private projectHashList;

    // Maps challengeIds to associated challenge data
    mapping(uint => Challenge.Data) public challenges;

    // Maps projectHashes to associated listing data
    mapping(bytes32 => Listing) public listings;

    // Global Variables
    VetXToken public token;
    PLCRVoting public voting;
    Parameterizer public parameterizer;
    ProjectController public projectController;

    // Store the amount of fund can be withdrawn by Ventureum team 
    uint private availableFundForVentureum;

    bytes32 constant BYTES_ZERO = 0x0;
    address constant ADDRESS_ZERO = 0x0;

    // ------------
    // CONSTRUCTOR
    // ------------
    /**
       @dev Contructor
       @notice Sets the addresses for token, voting, and parameterizer
       @param _kernelAddr Address of the kernel
       @param _tokenAddr Address of the native ERC20 token (ADT)
       @param _plcrAddr Address of a PLCR voting contract for the provided token
       @param _paramsAddr Address of a Parameterizer contract for the 
           provided PLCR voting contract
    */
    constructor(
        address _kernelAddr,
        address _tokenAddr,
        address _plcrAddr,
        address _paramsAddr,
        address _projectControllerAddr
    )
        public
        Module(_kernelAddr)
    {
        CI = keccak256("Registry");
        token = VetXToken(_tokenAddr);
        voting = PLCRVoting(_plcrAddr);
        parameterizer = Parameterizer(_paramsAddr);
        projectController = ProjectController(_projectControllerAddr);
    }

    // --------------------
    // PUBLISHER INTERFACE
    // --------------------
    /**
       @notice Allows a user to start an application.
       @notice Takes tokens from user and sets apply stage end time.
       @param _project The project of a potential listing a user 
           is applying to add to the registry
       @param _amount The number of ERC20 tokens a user is willing to potentially stake
    */
    function apply(string _project, uint _amount) external {
        require(!appWasMade(_project));
        require(!isWhitelisted(_project));
        require(_amount >= parameterizer.get("minDeposit"));

        // Transfers tokens from user to Registry contract
        require(token.transferFrom(msg.sender, this, _amount));

        // 50% of deposit becomes available to Ventureum team
        availableFundForVentureum = availableFundForVentureum.add(_amount.div(2));

        bytes32 projectHash = keccak256(bytes(_project));

        // Sets owner
        Listing storage listing = listings[projectHash];
        listing.owner = msg.sender;

        // Sets apply stage end time
        listing.applicationExpiry = block.timestamp.add(parameterizer.get("applyStageLen"));
        // 50% of the deposit becomes stake deposit. 
        listing.unstakedDeposit = _amount.sub(_amount.div(2));
        listing.projectName = _project;

        // Create a new project in ProjectController
        projectController.registerProject(projectHash, msg.sender, ADDRESS_ZERO);

        // insert to front
        projectHashList.insert(BYTES_ZERO, projectHash, projectHashList.getNext(BYTES_ZERO));

        emit _Application(msg.sender, _project, _amount);
    }

    /**
       @notice Allows the owner of a listing to remove the listing from the whitelist
       @notice Returns all tokens to the owner of the listing
       @param _project The project of a user's listing
    */
    function exit(string _project) external {
        Listing storage listing = listings[keccak256(bytes(_project))];

        require(msg.sender == listing.owner);
        require(!isWhitelisted(_project));
        
        // Cannot exit during ongoing challenge
        require(
            !challenges[listing.challengeId].isInitialized() || 
            challenges[listing.challengeId].isResolved()
        );

        // refund staked deposit.
        require(token.transfer(listing.owner, listing.unstakedDeposit));

        // Remove project & return tokens
        resetListing(_project);
    }

    // -----------------------
    // TOKEN HOLDER INTERFACE
    // -----------------------
    /**
       @notice Starts a poll for a project which is either
       @notice in the apply stage or already in the whitelist.
       @dev Tokens are taken from 
           the challenger and the applicant's deposit is locked.
       @param _project The project of an applicant's potential listing
    */
    function challenge(string _project) external returns (uint challengeId) {
        // Project must be in apply stage or already on the whitelist
        require(appWasMade(_project) || listing.whitelisted);
        
        bytes32 projectHash = keccak256(bytes(_project));
        Listing storage listing = listings[projectHash];

        require(now < listing.applicationExpiry, "Cannot challenge after application stage");

        // Challenger needs to stake equivalent amount of fund;
        uint _deposit = listing.unstakedDeposit;

        // Takes tokens from challenger
        require(token.transferFrom(msg.sender, this, _deposit));

        // Prevent multiple challenges
        require(
            !challenges[listing.challengeId].isInitialized() || 
            challenges[listing.challengeId].isResolved()
        );

        // Starts poll
        uint pollId = voting.startPoll(
            parameterizer.get("voteQuorum"),
            parameterizer.get("commitStageLen"),
            parameterizer.get("revealStageLen")
        );
        uint oneHundred = 100;
        challenges[pollId] = Challenge.Data({
            challenger: msg.sender,
            voting: voting,
            token: token,
            challengeId: pollId,
            rewardPool : oneHundred.sub(parameterizer.get("dispensationPct")).mul(_deposit).div(oneHundred),
            stake: _deposit,
            resolved: false,
            winningTokens: 0
            });

        // Updates listing to store most recent challenge
        listings[projectHash].challengeId = pollId;

        emit _Challenge(msg.sender, _project, _deposit, pollId);
        return pollId;
    }

    /**
       @notice Called by a voter to claim his/her reward for each completed vote.
       @dev Someone must call updateStatus() before this can be called.
       @param _challengeId The pollId of the challenge a reward is being claimed for
       @param _salt The salt of a voter's commit hash in the given poll
    */
    function claimReward(uint _challengeId, uint _salt) public {
        uint reward = challenges[_challengeId].claimReward(msg.sender, _salt);

        emit _RewardClaimed(msg.sender, _challengeId, reward);
    }

    /**
       @notice Updates a project's status from 'application' to 'listing'
           or resolves a challenge if one exists.
       @param _project The project whose status is being updated
    */
    function updateStatus(string _project) public {
        if (canBeWhitelisted(_project)) {
            whitelistApplication(_project);
            emit _NewProjectWhitelisted(_project);
        } else if (challengeCanBeResolved(_project)) {
            resolveChallenge(_project);
        }
    }

    // --------
    // GETTERS
    // --------

    /**
       @dev Determines whether the project of an application can be whitelisted.
       @param _project The project whose status should be examined
    */
    function canBeWhitelisted(string _project) public view returns (bool) {
        bytes32 projectHash = keccak256(bytes(_project));
        uint challengeId = listings[projectHash].challengeId;

        // Ensures that the application was made,
        // the application period has ended,
        // the project can be whitelisted,
        // and either: the challengeId == 0, or the challenge has been resolved.
        if (
            appWasMade(_project) && 
            isExpired(listings[projectHash].applicationExpiry) && 
            !isWhitelisted(_project) && 
            (!challenges[challengeId].isInitialized() || challenges[challengeId].isResolved())
            ) {
            return true;
        }

        return false;
    }

    /// @dev returns true if project is whitelisted
    function isWhitelisted(string _project) public view returns (bool whitelisted) {
        return listings[keccak256(bytes(_project))].whitelisted;
    }
    
    // @dev returns true if apply was called for this project
    function appWasMade(string _project) public view returns (bool exists) {
        return listings[keccak256(bytes(_project))].applicationExpiry > 0;
    }

    // @dev returns true if the application/listing has an unresolved challenge
    function challengeExists(string _project) public view returns (bool) {
        Challenge.Data storage _challenge = 
            challenges[listings[keccak256(bytes(_project))].challengeId];
        return _challenge.isInitialized() && !_challenge.isResolved();
    }

    /**
       @notice Determines whether voting has 
           concluded in a challenge for a given project.
       @dev Throws if no challenge exists.
       @param _project A project name with an unresolved challenge
    */
    function challengeCanBeResolved(string _project) public view returns (bool) {
        Challenge.Data storage _challenge = 
            challenges[listings[keccak256(bytes(_project))].challengeId];
        return _challenge.isInitialized() && _challenge.canBeResolved();
    }

    /**
       @notice Determines the number of tokens awarded to the winning party in a challenge.
       @param _challengeId The challengeId to determine a reward for
    */
    function challengeWinnerReward(uint _challengeId) public view returns (uint) {
        return challenges[_challengeId].challengeWinnerReward(); 
    }

    /// @dev returns true if the provided termDate has passed
    function isExpired(uint _termDate) public view returns (bool expired) {
        return _termDate < block.timestamp;
    }

    /**
       @dev Calculates the provided voter's token reward for the given poll.
       @param _voter The address of the voter whose reward balance is to be returned
       @param _challengeId The ID of the challenge the voter's reward is being calculated for
       @param _salt The salt of the voter's commit hash in the given poll
       @return The uint indicating the voter's reward (in nano-ADT)
    */
    function voterReward(address _voter, uint _challengeId, uint _salt)
        public view returns (uint) {
        return challenges[_challengeId].voterReward(_voter, _salt);
    }

    /**
       @dev Determines whether the provided voter has claimed tokens in a challenge
       @param _challengeId The ID of the challenge to 
           determine whether a voter has claimed tokens for
       @param _voter The address of the voter whose claim status is to be determined for the
           provided challenge.
       @return Bool indicating whether the voter has claimed tokens in the provided
           challenge
    */
    function tokenClaims(uint _challengeId, address _voter)
        public view returns (bool) {
        return challenges[_challengeId].tokenClaims[_voter];
    }

    function getNextProjectHash(bytes32 curr) public view returns (bytes32) {
        return projectHashList.getNext(curr);
    }

    // ----------------
    // PRIVATE FUNCTIONS
    // ----------------

    /**
       @dev Determines the winner in a challenge. Rewards the winner tokens and either 
           whitelists or de-whitelists the project.
       @param _project A project with a challenge that is to be resolved.
    */
    function resolveChallenge(string _project) private {
        bytes32 projectHash = keccak256(bytes(_project));
        Listing storage listing = listings[projectHash];
        Challenge.Data storage _challenge = challenges[listing.challengeId];

        // Calculates the winner's reward,
        // which is: (winner's full stake) + (dispensationPct * loser's stake)
        uint winnerReward = _challenge.challengeWinnerReward();

        _challenge.winningTokens = _challenge.voting.getTotalNumberOfTokensForWinningOption(
            _challenge.challengeId);
        _challenge.resolved = true;

        // Case: challenge failed
        if (voting.isPassed(_challenge.challengeId)) {
            whitelistApplication(_project);
            // Transfer the reward to applicant
            require(token.transfer(listing.owner, winnerReward));
            
            emit _ChallengeFailed(_challenge.challengeId);
            emit _NewProjectWhitelisted(_project);
        }
        // Case: challenge succeeded
        else {
            resetListing(_project);
            // Transfer the reward to the challenger
            require(token.transfer(_challenge.challenger, winnerReward));

            emit _ChallengeSucceeded(_challenge.challengeId);
            emit _ApplicationRemoved(_project);
            
        }
    }

    /**
       @dev Called by updateStatus() if the applicationExpiry date passed without a
           challenge being made
       @dev Called by resolveChallenge() if an application/listing beat a challenge.
       @param _project The project of an application/listing to be whitelisted
    */
    function whitelistApplication(string _project) private {
        bytes32 projectHash = keccak256(bytes(_project));
        listings[projectHash].whitelisted = true;
        
        // Update project state in projectController
        projectController.setState(projectHash, uint(ProjectController.ProjectState.AppAccepted));

        // transfer unstakedDeposit to listing owner after being whitelisted
        require(
            token.transfer(
                listings[projectHash].owner, 
                listings[projectHash].unstakedDeposit
            )
        );
    }

    /**
       @dev deletes a listing from the whitelist and transfers tokens back to owner
       @param _project the project to be removed
    */
    function resetListing(string _project) private {
        bytes32 projectHash = keccak256(bytes(_project));

        delete listings[projectHash].applicationExpiry;

        // remove project from projectController
        projectController.unregisterProject(projectHash);

        // remove project hash from DLL
        projectHashList.remove(projectHash);
    }

    /**
        Withdraw tokens from registry.
        it can only be called by owner (creator of the contract)
    */
    function withdraw () public onlyOwner {
        uint _amount = availableFundForVentureum;
        // reset available fund
        availableFundForVentureum = 0;

        require(token.transfer(owner, _amount));
        
        emit _WithdrawByVentureumTeam(msg.sender, _amount);
    }

    // ----------------
    // Following function(s) are backdoor functions which used for demo only.
    // All backdoor functions are `onlyOwner`. 
    // Those functions for us to change/add data, used to create a demo project more conveniently and quickly
    // ----------------

    /**
    * backdoor setting used to set all basic information for a projct

    * @param availableFund : the amount of fund can be withdrawn by Ventureum team 
    * @param applicationExpiry : expiration date of apply stage
    * @param whitelisted : a boolean shows the project is whitelisted or not
    * @param owner : the owner of this project.
    * @param unstakedDeposit : number of unlocked tokens with potential risk if challenged
    * @param challengeId : identifier of canonical challenge
    * @param projectName : the name of this project
    */
    function backDoorSetting(
        uint availableFund,
        uint applicationExpiry, 
        bool whitelisted,
        address owner,
        uint unstakedDeposit,
        uint challengeId,
        string projectName
    ) 
        external 
        onlyOwner 
    {
        availableFundForVentureum = availableFundForVentureum.add(availableFund);

        bytes32 projectHash = keccak256(bytes(projectName));

        Listing storage listing = listings[projectHash];
        listing.applicationExpiry = applicationExpiry;
        listing.whitelisted = whitelisted;
        listing.owner = owner;
        listing.unstakedDeposit = unstakedDeposit;
        listing.challengeId = challengeId;
        listing.projectName = projectName;
    }

    /**
    * Create a new project with the given project name.
    * insert this project hash to project hash list

    * @param projectName : the name of this project
    */
    function backDoorInsert(string projectName) external onlyOwner {
        bytes32 projectHash = keccak256(bytes(projectName));
        projectHashList.insert(BYTES_ZERO, projectHash, projectHashList.getNext(BYTES_ZERO));
    }

    /**
    * Remove an exist project 
    * remove the project hash from project hash list

    * @param projectName : the name of this project
    */
    function backDoorRemove(string projectName) external onlyOwner {
        bytes32 projectHash = keccak256(bytes(projectName));
        projectHashList.remove(projectHash);
    }

    /**
    * the given project will be challenged by the given challenger.
    * 
    * @param projectName : the name of this project
    * @param challenger : the address of the challenger
    * @param deposit : number of deposit already stored
    * @param pollId : the poll id already exist for a challenge poll.
    */
    function backDoorChallenge(
        string projectName, 
        address challenger, 
        uint deposit,
        uint pollId
    ) 
        external 
        onlyOwner 
    {
        bytes32 projectHash = keccak256(bytes(projectName));
        uint oneHundred = 100;

        Listing storage listing = listings[projectHash];

        challenges[pollId] = Challenge.Data({
            challenger: challenger,
            voting: voting,
            token: token,
            challengeId: pollId,
            rewardPool : oneHundred.sub(parameterizer.get("dispensationPct")).mul(deposit).div(oneHundred),
            stake: deposit,
            resolved: false,
            winningTokens: 0
            });

        listings[projectHash].challengeId = pollId;
    }
}
