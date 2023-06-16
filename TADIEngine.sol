//SPDX-License-Identifier: MIT
pragma solidity ^0.8.7;

import {Functions, FunctionsClient} from "./dev/functions/FunctionsClient.sol";
import "./strings.sol";

contract TADIEngine is FunctionsClient {
  using Functions for Functions.Request;
  using strings for *;

  struct Shipper {
    uint shipperID;
    address shipperAddy;
  }
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

  mapping(address => Shipper) public shippers;
  mapping(uint => address) public shipperIdToAddress;
  uint[] public shipperIndex;
  mapping(address => mapping(uint => Container)) public containers;
  mapping(uint => address) public containerIdToOwner;
  mapping(address => uint[]) public containerIndex;
  mapping(string => uint) public trackingNoToContainerId;
  mapping(uint => string) public containerIdToTrackingNo;

  address public owner;
  bool public active;

  bytes32 public latestRequestId;
  bytes public latestResponse;
  bytes public latestError;
  address public functions_oracle;
  string[] public latestTrackingData;

  uint public premium = 20000000000000000;
  uint public payout = 200000000000000000;
  uint public SEQ_shipperID = 0;
  uint public SEQ_containerID = 0;

  event OCRResponse(bytes32 indexed requestId, bytes result, bytes err);

  event Received(address _sender, uint _value);

  modifier OnlyOwner() {
    if (msg.sender != owner) {
      revert TADIEngine__NotOwner();
    }
    _;
  }
  modifier ContractActive() {
    if (!active) {
      revert TADIEngine__NotActive();
    }
    _;
  }

  error TADIEngine__NotOwner();
  error TADIEngine__NotActive();
  error TADIEngine__InvalidAmountSent(uint amount);

  constructor(address oracle) payable FunctionsClient(oracle) {
    owner = msg.sender;
    active = true;
    functions_oracle = oracle;
  }

  function newShipper(address _shipper) public returns (uint) {
    address shipperAddy;
    if (msg.sender == owner) {
      shipperAddy = _shipper;
    } else {
      shipperAddy = msg.sender;
    }
    SEQ_shipperID++;
    shippers[shipperAddy] = Shipper(SEQ_shipperID, shipperAddy);
    shipperIdToAddress[SEQ_shipperID] = shipperAddy;
    shipperIndex.push(SEQ_shipperID);
    return SEQ_shipperID;
  }

  function addContainer(
    address _shipper,
    string memory _origin,
    uint _gWeight,
    string memory _trackingNumber,
    uint _dueDate
  ) public payable returns (uint) {
    address shipperAddy;
    if (msg.sender == owner) {
      shipperAddy = _shipper;
    } else {
      shipperAddy = msg.sender;
    }
    SEQ_containerID++;
    containers[shipperAddy][SEQ_containerID] = Container(
      SEQ_containerID,
      shippers[shipperAddy].shipperID,
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
    containerIdToOwner[SEQ_containerID] = shipperAddy;
    containerIndex[shipperAddy].push(SEQ_containerID);
    containerIdToTrackingNo[SEQ_containerID] = _trackingNumber;
    return SEQ_containerID;
  }

  function getTrackingNumber(uint _containerID) public view returns (string memory) {
    return containerIdToTrackingNo[_containerID];
  }

  function getContainerId(string memory _trackingNumber) public view returns (uint) {
    return trackingNoToContainerId[_trackingNumber];
  }

  function purchaseDelayProtection(uint _containerID) public payable {
    if (msg.value < premium) {
      revert TADIEngine__InvalidAmountSent(msg.value);
    }
    containers[getContainerOwner(_containerID)][_containerID].delayProtection = true;
  }

  receive() external payable {
    emit Received(msg.sender, msg.value);
  }

  function simulateDelay(uint _containerID) public {
    containers[getContainerOwner(_containerID)][_containerID].dueDate = block.timestamp - 86400;
  }

  function checkForDelay(uint _containerID) public {
    uint dueDatez = containers[getContainerOwner(_containerID)][_containerID].dueDate;
    if (block.timestamp > dueDatez && containers[getContainerOwner(_containerID)][_containerID].delayProtection) {
      insurancePayout(_containerID);
      containers[getContainerOwner(_containerID)][_containerID].delayProtection = false;
    }
  }

  function insurancePayout(uint _containerID) internal ContractActive {
    address ownah = getContainerOwner(_containerID);
    payable(ownah).transfer(payout);
  }

  function modifyGrossWeight(address _shipper, uint _containerID, uint newWeight) public ContractActive returns (uint) {
    address shipperAddy;
    if (msg.sender == owner) {
      shipperAddy = _shipper;
    } else {
      shipperAddy = msg.sender;
    }
    containers[shipperAddy][_containerID].grossWeight = newWeight;
    return newWeight;
  }

  function getLatestLocation(uint _containerID) public view OnlyOwner returns (string memory) {
    return containers[getContainerOwner(_containerID)][_containerID].latestLoc;
  }

  function getLatestTimestamp(uint _containerID) public view OnlyOwner returns (uint) {
    return containers[getContainerOwner(_containerID)][_containerID].latestTimestamp;
  }

  function concludeContainer(
    // address _shipper,
    uint _containerID
  ) public OnlyOwner ContractActive returns (bool) {
    containers[getContainerOwner(_containerID)][_containerID].active = false;
    return true;
  }

  function reactivateContainer(
    // address _shipper,
    uint _containerID
  ) public OnlyOwner returns (bool) {
    containers[getContainerOwner(_containerID)][_containerID].active = true;
    return true;
  }

  function getContainerOwner(uint _containerID) public view returns (address) {
    return containerIdToOwner[_containerID];
  }

  function getShipperAddressById(uint _shipperId) public view returns (address) {
    return shipperIdToAddress[_shipperId];
  }

  function executeRequest(
    string calldata source,
    bytes calldata secrets,
    string[] calldata args,
    uint64 subscriptionId,
    uint32 gasLimit
  ) public OnlyOwner returns (bytes32) {
    Functions.Request memory req;
    req.initializeRequest(Functions.Location.Inline, Functions.CodeLanguage.JavaScript, source);
    if (secrets.length > 0) {
      req.addRemoteSecrets(secrets);
    }
    if (args.length > 0) req.addArgs(args);

    bytes32 assignedReqID = sendRequest(req, subscriptionId, gasLimit);
    latestRequestId = assignedReqID;
    return assignedReqID;
  }

  function fulfillRequest(bytes32 requestId, bytes memory response, bytes memory err) internal override {
    latestResponse = response;
    latestError = err;
    

    bool nilErr = (err.length == 0);
    if (nilErr) {
      string memory snapshot = string(response);
      latestTrackingData = smt(snapshot);
    }
    emit OCRResponse(requestId, response, err);
  }

  function trackingUpdater(uint _containerId) public OnlyOwner {
    containers[getContainerOwner(_containerId)][_containerId].latestLoc = latestTrackingData[0];
    containers[getContainerOwner(_containerId)][_containerId].latestTimestamp = st2num(latestTrackingData[1]);
  }

  function ltrTester(string memory _loc, string memory _time) public OnlyOwner {
    latestTrackingData[0] = _loc;
    latestTrackingData[1] = _time;
  }

  function smt(string memory _snapshot) public pure returns (string[] memory) {
    strings.slice memory s = _snapshot.toSlice();
    strings.slice memory delim = "-".toSlice();
    string[] memory parts = new string[](s.count(delim) + 1);
    for (uint i = 0; i < parts.length; i++) {
      parts[i] = s.split(delim).toString();
    }
    return parts;
  }

  function st2num(string memory numString) public pure returns (uint) {
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
}
// Germany-169872345
