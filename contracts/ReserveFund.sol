// SPDX-License-Identifier: MIT

pragma solidity 0.6.12;

import "./lib/IERC20.sol";
import "./lib/SafeERC20.sol";

contract ReserveFund{
    using SafeERC20 for IERC20;

    struct Proposal {
        address proposer;
        uint256 deadline;
        uint256 readyToExecutionTime;
        uint256 cancellationTime;
        uint256 YES;
        uint256 NO;
        bool executed;
        address to;
        uint256 amount;
    }

    struct BUSYINFO{
        bool busy;
        uint256 voting_id;
    }

    enum ProposalState{
        Unknown,
        Failed,
        Cancelled,
        Active,
        Succeeded,
        ExecutionWaiting,
        Executed
    }

    IERC20 immutable public marsToken;
    IERC20 immutable public governanceToken;

    uint256 constant public PROPOSAL_CREATION_FEE= 100*1e18;//mars
    uint256 constant public PROPOSER_LOCKUP_AMOUNT = 1000*1e18;//GMARSDAO

    uint256 constant public MIN_VOTING_LOCKUP_AMOUNT = 100*1e18;
    uint256 constant public MAX_VOTING_LOCKUP_AMOUNT = 30000*1e18;

    uint256 constant public QUORUM_VOTES =100_000*1e18;
    uint256 constant public EXECUTION_WAITING_PERIOD = 5 days;
    uint256 constant public EXECUTION_LOCK_PERIOD = 4 days;
    uint256 constant public VOTING_PERIOD = 3 days;
    address public constant burnAddress =
        0x000000000000000000000000000000000000dEaD;

    Proposal[] public proposals;
    mapping(uint256 => mapping(address => uint256)) public userLockupAmount;
    mapping(address=>BUSYINFO) public recipients;
    
    event ProposalCreated(uint256 proposalId);
    event VoteCast(uint256 proposalId, address voter,uint256 votes,bool support);
    event ProposalExecuted(uint256 proposalId);
    
    modifier exists(uint256 _proposalId) {
        require(state(_proposalId)!=ProposalState.Unknown,"proposal not exist");
        _;
    }

    constructor(address _marsTokenAddress,address _governanceTokenAddress) public{
        marsToken=IERC20(_marsTokenAddress);
        governanceToken=IERC20(_governanceTokenAddress);
    }

    function propose(address _to,uint256 _amount) external returns (uint256){
        
        BUSYINFO storage recipient=recipients[_to];
        require(recipient.busy==false || state(recipient.voting_id) < ProposalState.Active, 
        "proposal for {_to} address already exists.");
        
        uint256 proposalId=proposals.length;
        recipient.busy=true;recipient.voting_id=proposalId;

        marsToken.safeTransferFrom(
            address(msg.sender),
            burnAddress,
            PROPOSAL_CREATION_FEE
        );
        
        governanceToken.safeTransferFrom(
            address(msg.sender),
            address(this),
            PROPOSER_LOCKUP_AMOUNT
        );

        proposals.push(Proposal({
            proposer : msg.sender,
            deadline : block.timestamp+VOTING_PERIOD,
            readyToExecutionTime : block.timestamp+EXECUTION_LOCK_PERIOD,
            cancellationTime : block.timestamp+EXECUTION_WAITING_PERIOD,
            YES : 0,
            NO : 0,
            executed : false,
            to: _to,
            amount:_amount
        }));

        emit ProposalCreated(
            proposalId
        );

        return proposalId;
    }

    function verifyCallResult(
        bool success,
        bytes memory returndata,
        string memory errorMessage
    ) internal pure returns (bytes memory) {
        if (success) {
            return returndata;
        } else {
            // Look for revert reason and bubble it up if present
            if (returndata.length > 0) {
                // The easiest way to bubble the revert reason is using memory via assembly

                // solhint-disable-next-line no-inline-assembly
                assembly {
                    let returndata_size := mload(returndata)
                    revert(add(32, returndata), returndata_size)
                }
            } else {
                revert(errorMessage);
            }
        }
    }


    function execute(uint256 proposalId) external{

        require(state(proposalId) == ProposalState.ExecutionWaiting, "execution not available");
        Proposal storage proposal = proposals[proposalId];
        proposal.executed=true;
        recipients[proposal.to].busy=false;
        (bool success, bytes memory returndata) = 
                address(marsToken).call(
                    abi.encodeWithSelector(marsToken.transfer.selector, proposal.to, proposal.amount)
                );
        verifyCallResult(success, returndata, "execution failed");

        emit ProposalExecuted(proposalId);
    }


    function castVote(uint256 proposalId,uint256 votes,bool support) external exists(proposalId){
        require(state(proposalId) == ProposalState.Active, "voting is closed");
        Proposal storage proposal = proposals[proposalId];
        require(userLockupAmount[proposalId][msg.sender] == 0, "already voted");
        require(votes>=MIN_VOTING_LOCKUP_AMOUNT, "votes is too little");
        require(votes<=MAX_VOTING_LOCKUP_AMOUNT, "votes is too much");
        governanceToken.safeTransferFrom(
            address(msg.sender),
            address(this),
            votes
        );

        userLockupAmount[proposalId][msg.sender] = votes;

        if(support){
            proposal.YES+=votes;
        }else{
            proposal.NO+=votes;
        }

        emit VoteCast(proposalId, msg.sender,votes,support);
    }

    function getBackProposalStake(uint256 proposalId) external exists(proposalId){
        ProposalState currentState = state(proposalId);
        require(currentState < ProposalState.Active || currentState ==  ProposalState.Executed, 
        "voting is not closed yet");
        Proposal storage proposal = proposals[proposalId];
        require(proposal.proposer==msg.sender,"caller not proposer");
        governanceToken.safeTransfer(
            proposal.proposer,
            PROPOSER_LOCKUP_AMOUNT
        );
    }

    function getBackVotingStake(uint256 proposalId) external exists(proposalId){
        require(state(proposalId) != ProposalState.Active, "voting is not closed yet");
        uint256 stakeAmount=userLockupAmount[proposalId][msg.sender];
        require(stakeAmount > 0, "your stake is 0");
        userLockupAmount[proposalId][msg.sender]=0;
        governanceToken.safeTransfer(
            address(msg.sender),
            stakeAmount
        );
    }

    function proposalsCount() public view returns (uint256) {
        return proposals.length;
    }

    function getProposalParameters(uint256 proposalId) public view exists(proposalId) returns (address,uint256) {
        Proposal storage p = proposals[proposalId];
        return (p.to,p.amount);
    }
    
    function state(uint256 proposalId) public view returns (ProposalState) {
        
        if(proposalId<proposals.length){
            Proposal storage proposal = proposals[proposalId];
            
            if (proposal.deadline > block.timestamp) {
                return ProposalState.Active;
            }
            
            if((proposal.YES+proposal.NO)>=QUORUM_VOTES && proposal.YES>proposal.NO){

                if (proposal.executed) {
                    return ProposalState.Executed;
                }

                if(proposal.readyToExecutionTime>block.timestamp){
                    return ProposalState.Succeeded;
                }

                if (proposal.cancellationTime > block.timestamp) {
                    return ProposalState.ExecutionWaiting;
                }

                return ProposalState.Cancelled;

            }else{
                if(proposal.readyToExecutionTime>block.timestamp){
                    return ProposalState.Failed;
                } 
            } 
        }
        
        return ProposalState.Unknown;
    }



}