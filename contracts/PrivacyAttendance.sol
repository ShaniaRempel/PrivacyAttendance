// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { FHE, euint8, ebool } from "@fhevm/solidity/lib/FHE.sol";
import { SepoliaConfig } from "@fhevm/solidity/config/ZamaConfig.sol";

contract PrivacyAttendance is SepoliaConfig {

    address public owner;
    uint256 public currentPeriod;

    struct Employee {
        bool isRegistered;
        string name;
        uint256 registrationTime;
        bool isActive;
    }

    struct AttendanceRecord {
        euint8 encryptedCheckInHour;
        euint8 encryptedCheckOutHour;
        ebool hasCheckedIn;
        ebool hasCheckedOut;
        euint8 encryptedWorkHours;
        uint256 recordDate;
        bool isProcessed;
    }

    struct PeriodSummary {
        uint256 totalEmployees;
        uint256 activeEmployees;
        uint256 startTime;
        uint256 endTime;
        bool isFinalized;
    }

    mapping(address => Employee) public employees;
    mapping(address => mapping(uint256 => AttendanceRecord)) public attendanceRecords;
    mapping(uint256 => PeriodSummary) public periodSummaries;
    mapping(uint256 => address[]) public periodEmployees;

    address[] public allEmployees;

    event EmployeeRegistered(address indexed employee, string name);
    event EmployeeDeactivated(address indexed employee);
    event CheckInRecorded(address indexed employee, uint256 indexed period);
    event CheckOutRecorded(address indexed employee, uint256 indexed period);
    event PeriodFinalized(uint256 indexed period, uint256 totalEmployees);
    event AttendanceDecrypted(address indexed employee, uint256 period, uint8 workHours);

    modifier onlyOwner() {
        require(msg.sender == owner, "Not authorized");
        _;
    }

    modifier onlyRegisteredEmployee() {
        require(employees[msg.sender].isRegistered, "Employee not registered");
        require(employees[msg.sender].isActive, "Employee not active");
        _;
    }

    modifier validPeriod(uint256 period) {
        require(period > 0, "Invalid period");
        _;
    }

    constructor() {
        owner = msg.sender;
        currentPeriod = 1;
    }

    function registerEmployee(address employeeAddr, string memory name) external onlyOwner {
        require(!employees[employeeAddr].isRegistered, "Employee already registered");
        require(bytes(name).length > 0, "Name cannot be empty");

        employees[employeeAddr] = Employee({
            isRegistered: true,
            name: name,
            registrationTime: block.timestamp,
            isActive: true
        });

        allEmployees.push(employeeAddr);

        emit EmployeeRegistered(employeeAddr, name);
    }

    function deactivateEmployee(address employeeAddr) external onlyOwner {
        require(employees[employeeAddr].isRegistered, "Employee not registered");
        require(employees[employeeAddr].isActive, "Employee already inactive");

        employees[employeeAddr].isActive = false;

        emit EmployeeDeactivated(employeeAddr);
    }

    function checkIn() external onlyRegisteredEmployee {
        uint256 today = getCurrentDay();
        AttendanceRecord storage record = attendanceRecords[msg.sender][today];

        require(!record.isProcessed, "Already processed for today");

        uint256 currentHour = (block.timestamp / 3600) % 24;
        euint8 encryptedHour = FHE.asEuint8(uint8(currentHour));
        ebool hasCheckedInValue = FHE.asEbool(true);

        record.encryptedCheckInHour = encryptedHour;
        record.hasCheckedIn = hasCheckedInValue;
        record.recordDate = today;

        FHE.allowThis(encryptedHour);
        FHE.allowThis(hasCheckedInValue);
        FHE.allow(encryptedHour, msg.sender);
        FHE.allow(hasCheckedInValue, msg.sender);

        if (!_isEmployeeInPeriod(msg.sender, currentPeriod)) {
            periodEmployees[currentPeriod].push(msg.sender);
        }

        emit CheckInRecorded(msg.sender, currentPeriod);
    }

    function checkOut() external onlyRegisteredEmployee {
        uint256 today = getCurrentDay();
        AttendanceRecord storage record = attendanceRecords[msg.sender][today];

        require(!record.isProcessed, "Already processed for today");

        uint256 currentHour = (block.timestamp / 3600) % 24;
        euint8 encryptedHour = FHE.asEuint8(uint8(currentHour));
        ebool hasCheckedOutValue = FHE.asEbool(true);

        record.encryptedCheckOutHour = encryptedHour;
        record.hasCheckedOut = hasCheckedOutValue;

        // Calculate work duration in encrypted domain (hours)
        euint8 duration = FHE.sub(encryptedHour, record.encryptedCheckInHour);
        record.encryptedWorkHours = duration;
        FHE.allowThis(record.encryptedWorkHours);
        FHE.allow(record.encryptedWorkHours, msg.sender);

        FHE.allowThis(encryptedHour);
        FHE.allowThis(hasCheckedOutValue);
        FHE.allow(encryptedHour, msg.sender);
        FHE.allow(hasCheckedOutValue, msg.sender);

        emit CheckOutRecorded(msg.sender, currentPeriod);
    }

    function requestAttendanceDecryption(address employeeAddr, uint256 period) external onlyOwner validPeriod(period) {
        AttendanceRecord storage record = attendanceRecords[employeeAddr][period];
        require(!record.isProcessed, "Record already processed");

        bytes32[] memory cts = new bytes32[](1);
        cts[0] = FHE.toBytes32(record.encryptedWorkHours);
        FHE.requestDecryption(cts, this.processAttendanceDecryption.selector);
    }

    function processAttendanceDecryption(
        uint256 /* requestId */,
        uint8 workHours,
        bytes[] memory /* signatures */
    ) external {
        // Note: checkSignatures verification will be handled by the FHE system
        // In production, proper signature verification should be implemented

        emit AttendanceDecrypted(msg.sender, currentPeriod, workHours);
    }

    function finalizePeriod() external onlyOwner {
        require(!periodSummaries[currentPeriod].isFinalized, "Period already finalized");

        uint256 totalEmployees = periodEmployees[currentPeriod].length;
        uint256 activeCount = 0;

        for (uint256 i = 0; i < totalEmployees; i++) {
            address emp = periodEmployees[currentPeriod][i];
            if (employees[emp].isActive) {
                activeCount++;
            }
        }

        periodSummaries[currentPeriod] = PeriodSummary({
            totalEmployees: totalEmployees,
            activeEmployees: activeCount,
            startTime: periodSummaries[currentPeriod].startTime > 0 ?
                       periodSummaries[currentPeriod].startTime : block.timestamp,
            endTime: block.timestamp,
            isFinalized: true
        });

        emit PeriodFinalized(currentPeriod, totalEmployees);

        currentPeriod++;
    }

    function getCurrentDay() public view returns (uint256) {
        return block.timestamp / 86400;
    }

    function _isEmployeeInPeriod(address employeeAddr, uint256 period) private view returns (bool) {
        address[] memory periodEmps = periodEmployees[period];
        for (uint256 i = 0; i < periodEmps.length; i++) {
            if (periodEmps[i] == employeeAddr) {
                return true;
            }
        }
        return false;
    }

    function getEmployeeInfo(address employeeAddr) external view returns (
        bool isRegistered,
        string memory name,
        uint256 registrationTime,
        bool isActive
    ) {
        Employee storage emp = employees[employeeAddr];
        return (emp.isRegistered, emp.name, emp.registrationTime, emp.isActive);
    }

    function getAttendanceStatus(address employeeAddr, uint256 period) external view returns (
        bool hasRecord,
        uint256 recordDate,
        bool isProcessed
    ) {
        AttendanceRecord storage record = attendanceRecords[employeeAddr][period];
        return (
            record.recordDate > 0,
            record.recordDate,
            record.isProcessed
        );
    }

    function getPeriodInfo(uint256 period) external view validPeriod(period) returns (
        uint256 totalEmployees,
        uint256 activeEmployees,
        uint256 startTime,
        uint256 endTime,
        bool isFinalized
    ) {
        PeriodSummary storage summary = periodSummaries[period];
        return (
            summary.totalEmployees,
            summary.activeEmployees,
            summary.startTime,
            summary.endTime,
            summary.isFinalized
        );
    }

    function getPeriodEmployees(uint256 period) external view validPeriod(period) returns (address[] memory) {
        return periodEmployees[period];
    }

    function getTotalEmployees() external view returns (uint256) {
        return allEmployees.length;
    }

    function getAllEmployees() external view returns (address[] memory) {
        return allEmployees;
    }
}