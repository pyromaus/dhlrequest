//SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Functions, FunctionsClient} from "./dev/functions/FunctionsClient.sol";
import "./strings.sol";

contract TADIEngine {
  using Functions for Functions.Request;

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
  mapping(uint => uint[]) public trackingNoToContainerIds;
  mapping(uint => uint) public containerIdToTrackingNo;

  address public owner;
  bool public active;

  bytes32 public latestRequestId;
  bytes public latestResponse;
  bytes public latestError;
  address public s_oracle;
  string[] latestTrackingData;

  uint public premium = 20000000000000000;
  uint public payout = 200000000000000000;
  uint public SEQ_shipperID = 0;
  uint public SEQ_containerID = 0;

  event OCRResponse(bytes32 indexed requestId, bytes result, bytes err);

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
    s_oracle = oracle;
  }

  function newShipper(address _shipper) public returns (uint) {
    address shipperAddy;
    if (msg.sender = owner) {
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
    uint _trackingNumber,
    uint _dueDate
  ) public payable returns (uint) {
    if (msg.value < premium) {
      revert TADIEngine__InvalidAmountSent(msg.value);
    }
    address shipperAddy;
    if (msg.sender = owner) {
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

  function getTrackingNumber(uint _containerID) public view returns (uint) {
    return containerIdToTrackingNo[_containerID];
  }

  function purchaseDelayProtection(uint _containerID) public payable {
    if (msg.value < premium) {
      revert TADIEngine__InvalidAmountSent(msg.value);
    }
    containers[getContainerOwner(_containerID)][_containerID].delayProtection = true;
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
    if (msg.sender = owner) {
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

  function getLatestTimestamp(uint _containerID) public view OnlyOwner returns (string memory) {
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
    emit OCRResponse(requestId, response, err);

    bool nilErr = (err.length == 0);
    if (nilErr) {
      string snapshot = abi.decode(response, (string));
      latestTrackingData = smt(snapshot);
    }
  }

  function trackingUpdater(uint _containerId) public OnlyOwner {
    containers[getContainerOwner(_containerId)][_containerId].latestLoc = latestTrackingData[0];
    containers[getContainerOwner(_containerId)][_containerId].latestTimestamp = latestTrackingData[1].toNumber();
  }

  function ltrTester(string _loc, uint _time) public OnlyOwner {
    latestTrackingData[0] = _loc;
    latestTrackingData[1] = _time;
  }

  function smt(string memory _snapshot) public returns (string[] memory) {
    strings.slice memory s = _snapshot.toSlice();
    strings.slice memory delim = "-".toSlice();
    string[] memory parts = new string[](s.count(delim) + 1);
    for (uint i = 0; i < parts.length; i++) {
      parts[i] = s.split(delim).toString();
    }
    return parts;
  }
  // Germany-169872345
  // 52.115421, 4.280247 = 052 115421 004 280247

  // function convertUintResponseToCoordStruct(
  //     uint _coordsFromOracle
  // ) internal returns (Coordinates memory) {
  //     string memory latitude;
  //     string memory longitude;
}

// anyone can track the package with the advantage of
// having tracking without anyone knowing that youre tracking it
// cos its just a view function, theres no URL being visited and
// thereby tracked/pinged to the feds

// when you log on to any package tracking service on Web2, in the best
// case, they know somebody triggered a tracking info fetch at a known
// point in time (in the worst case, they identified the person) cos
// their server gets a ping when someone connects and loads the page etc.
// this can potentially put the package under greater scrutiny
//
// with this smart contract, the tracking info is written on-chain.
// the only pinging being done here is by the party updating the
// coordinates. the end-user calls a view function to see the latest
// coordinates, which doesn't leave a trace that anyone called anything

// check if the view function callers are invisible when they do it

// bro sell this to the
// theres a massive upside to this
// millions of volume per site

// i have like 50 mil
// i have like 50 mil bro
// i have like 50 mill bro
// i have like 50 mill bro
// i rly dont care about the cash
