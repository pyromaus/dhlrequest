//SPDX-License-Identifier: MIT
pragma solidity ^0.8.7;

/**
 * @title TADIEngine 
 * @author Serge Fotiev
 * @notice Tracking and Delay Insurance (TADI). This parametric insurance 
 * contract will allow a shipping client to purchase delay protection for their 
 * shipping container. Access to Etherisc risk pools not yet implemented.
 * Also makes use of Chainlink Functions (beta) to call the
 * DHL unified shipment tracking API with the Chainlink DON to fetch the 
 * current location and timestamp of a given tracking number.
 * @dev Chainlink Functions (beta) - Mumbai
 */

import {Functions, FunctionsClient} from "./dev/functions/FunctionsClient.sol";
import "./strings.sol";

error TADIEngine__NotOwner();
error TADIEngine__InvalidAmountSent(uint amount);

contract TADIEngine is FunctionsClient {
  using Functions for Functions.Request;
  using strings for *;

  /* structs */

  /* when the contract refers to the shipper, we mean the 
  owner who is managing/tracking/awaiting their shipments */

  struct Shipper {
    uint shipperID;
    address shipperAddress;
  }

  /* container refers to the shipment owned by the shipper */ 

  struct Container {
    uint containerID;
    uint shipperID;
    uint grossWeight;
    string origin;
    uint originTimestamp;
    string latestLoc;
    uint latestTimestamp;
    string trackingNumber;
    bool active;
    uint dueDate;
    bool delayProtection;
  }

  /* state variables */ 

  mapping(address => Shipper) private s_shippers;
  mapping(uint => address) private s_shipperIdToAddress;
  uint[] private s_shipperIndex;
  mapping(address => mapping(uint => Container)) private s_containers;
  mapping(uint => address) private s_containerIdToOwner;
  mapping(address => uint[]) private s_containerIndex;
  mapping(uint => string) private s_containerIdToTrackingNo;

  address private immutable i_owner;
  string[] private s_latestTrackingData;
  uint private s_containerIdToTrack;
  uint private s_premium = 20000000000000000; // 0.02 MATIC
  uint private s_payout = 200000000000000000; // 0.20 MATIC
  uint private SEQ_shipperID = 0;
  uint private SEQ_containerID = 0;

  // Chainlink Functions variables
  bytes32 public latestRequestId;
  bytes public latestResponse;
  bytes public latestError;

  /* events */

  event OCRResponse(bytes32 indexed requestId, bytes result, bytes err);
  event Received(address _sender, uint _value);
  event ShipperCreated(address indexed _shipper);
  event ContainerCreated(address indexed _shipper, uint indexed _containerID);

  modifier OnlyOwner() {
    if (msg.sender != i_owner) {
      revert TADIEngine__NotOwner();
    }
    _;
  }

  constructor (address oracle) payable FunctionsClient(oracle) {
    i_owner = msg.sender;
  }

  receive() external payable {
    emit Received(msg.sender, msg.value);
  }

  /**@dev An interaction with the Etherisc risk pools will
   * be implemented in this function. The protection buyer
   * will pay a premium for risk pool access. If shipment is
   * late, the smart contract acts accordingly and the buyer
   * is paid immediately.
   */
  function purchaseDelayProtection(uint _containerID) external payable {
    if (msg.value < s_premium) {
      revert TADIEngine__InvalidAmountSent(msg.value);
    }
    s_containers[getContainerOwner(_containerID)][_containerID].delayProtection = true;
  }

  /** @dev Here we set the shipment's due date to yesterday,
   * to simulate a delay and warrant a payout.
   */
  function simulateDelay(uint _containerID) external {
    s_containers[getContainerOwner(_containerID)][_containerID].dueDate = block.timestamp - 86400;
  }

  /** @dev If current block time is past the due date, and 
   * the buyer has delay protection purchased, 
   * they are paid immediately by this contract.
   */
  function checkForDelay(uint _containerID) external {
    uint dueDatez = s_containers[getContainerOwner(_containerID)][_containerID].dueDate;
    if (block.timestamp > dueDatez && s_containers[getContainerOwner(_containerID)][_containerID].delayProtection) {
      s_containers[getContainerOwner(_containerID)][_containerID].delayProtection = false;
      insurancePayout(_containerID);
    }
  }

  function newShipper(address _shipper) public returns (uint) {
    SEQ_shipperID++;
    s_shippers[_shipper] = Shipper(SEQ_shipperID, _shipper);
    s_shipperIdToAddress[SEQ_shipperID] = _shipper;
    s_shipperIndex.push(SEQ_shipperID);
    emit ShipperCreated(_shipper);
    return SEQ_shipperID;
  }

  /**@dev adds a new shipment with data on its owner,
   * ID, weight, origin and last location with timestamps,
   * tracking number and due date.
   * Delay protection is not included and may be 
   * purchased by calling purchaseDelayProtection()
   */
  function addContainer(
    address _shipper,
    string memory _origin,
    uint _gWeight,
    string memory _trackingNumber,
    uint _dueDate
  ) public returns (uint) {
    SEQ_containerID++;
    s_containers[_shipper][SEQ_containerID] = Container(
      SEQ_containerID,
      s_shippers[_shipper].shipperID,
      _gWeight,
      _origin,
      block.timestamp,
      _origin,
      block.timestamp,
      _trackingNumber,
      true,
      _dueDate,
      false
    );
    s_containerIdToOwner[SEQ_containerID] = _shipper;
    s_containerIndex[_shipper].push(SEQ_containerID);
    s_containerIdToTrackingNo[SEQ_containerID] = _trackingNumber;
    emit ContainerCreated(_shipper, SEQ_containerID);
    return SEQ_containerID;
  }

  function concludeShipment(
    uint _containerID
  ) public OnlyOwner returns (bool) {
    s_containers[getContainerOwner(_containerID)][_containerID].active = false;
    return true;
  }

  function activateShipment(
    uint _containerID
  ) public OnlyOwner returns (bool) {
    s_containers[getContainerOwner(_containerID)][_containerID].active = true;
    return true;
  }

  /**@dev Builds a Chainlink Functions request;
   * Chainlink executes our DHL shipment
   * tracking API request on 10 different 
   * decentralised oracle nodes and aggregates
   * a single response.
   * Currently only callable in Javascript
   */
  function requestShipmentTracking(
    string calldata source,
    bytes calldata secrets,
    string[] calldata args,
    uint64 subscriptionId,
    uint32 gasLimit,
    uint _containerID
  ) public OnlyOwner returns (bytes32) {
    Functions.Request memory req;
    req.initializeRequest(Functions.Location.Inline, Functions.CodeLanguage.JavaScript, source);
    if (secrets.length > 0) {
      req.addRemoteSecrets(secrets);
    }
    if (args.length > 0) req.addArgs(args);

    bytes32 assignedReqID = sendRequest(req, subscriptionId, gasLimit);
    latestRequestId = assignedReqID;
    s_containerIdToTrack = _containerID;
    return assignedReqID;
  }

  /**@dev Chainlink Functions callback
   * Called by Chainlink DON when they have our 
   * tracking data response ready
   */
  function fulfillRequest(bytes32 requestId, bytes memory response, bytes memory err) internal override {
    latestResponse = response;
    latestError = err;

    bool nilErr = (err.length == 0);
    if (nilErr) {
      string memory trackingInfo = string(response);
      s_latestTrackingData = smt(trackingInfo);
    }
    writeTrackingResponseToContainer(s_containerIdToTrack);
    emit OCRResponse(requestId, response, err);
  }

  function writeTrackingResponseToContainer(uint _containerId) internal {
    s_containers[getContainerOwner(_containerId)][_containerId].latestLoc = s_latestTrackingData[0];
    s_containers[getContainerOwner(_containerId)][_containerId].latestTimestamp = st2num(s_latestTrackingData[1]);
  }

  function insurancePayout(uint _containerID) internal {
    address owner = getContainerOwner(_containerID);
    payable(owner).transfer(s_payout);
  }

  /**@dev Tracking data is received as the
   * shipment location and timestamp in one string
   * for example "Germany-1683486969"
   * This function splits this single string in two
   */
  function smt(string memory _snapshot) internal pure returns (string[] memory) {
    strings.slice memory s = _snapshot.toSlice();
    strings.slice memory delim = "-".toSlice();
    string[] memory parts = new string[](s.count(delim) + 1);
    for (uint i = 0; i < parts.length; i++) {
      parts[i] = s.split(delim).toString();
    }
    return parts;
  }

  /**@dev Once the location and timestamp are seperated, 
   * the timestamp is a still a string. This function converts
   * it to a uint256
   * "1683486969" --> 1683486969
   */
  function st2num(string memory numString) internal pure returns (uint) {
    uint val = 0;
    bytes memory stringBytes = bytes(numString);
    for (uint i = 0; i < stringBytes.length; i++) {
      uint exp = stringBytes.length - i;
      bytes1 ival = stringBytes[i];
      uint8 uval = uint8(ival);
      uint jval = uval - uint(0x30);

      val += (uint(jval) * (10 ** (exp - 1)));
    }
    return val;
  }

  /* Getter functions */

  function getContainerOwner(uint _containerID) public view returns (address) {
    return s_containerIdToOwner[_containerID];
  }

  function getShipperAddressById(uint _shipperId) public view returns (address) {
    return s_shipperIdToAddress[_shipperId];
  }

  function getLatestLocation(uint _containerID) public view returns (string memory) {
    return s_containers[getContainerOwner(_containerID)][_containerID].latestLoc;
  }

  function getLatestTimestamp(uint _containerID) public view returns (uint) {
    return s_containers[getContainerOwner(_containerID)][_containerID].latestTimestamp;
  }

  function getTrackingNumber(uint _containerID) public view returns (string memory) {
    return s_containerIdToTrackingNo[_containerID];
  }

  function getContainerIds(address _shipper) public view returns (uint[] memory) {
    return s_containerIndex[_shipper];
  }
}
