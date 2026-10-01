// HL7 attribute facts: https://www.hl7.eu/HL7v2x/v231/
// Independent Swift representation; no HL7kit implementation code.
extension HL7Tables {
    static let v2_3_1: [String: String] = [
        "MSH": """
        1|Field Separator|ST|R|1|1||2.3.1|
        2|Encoding Characters|ST|R|1|4||2.3.1|
        3|Sending Application|HD|O|1|180|0361|2.3.1|
        4|Sending Facility|HD|O|1|180|0362|2.3.1|
        5|Receiving Application|HD|O|1|180|0361|2.3.1|
        6|Receiving Facility|HD|O|1|180|0362|2.3.1|
        7|Date/Time Of Message|TS|O|1|26||2.3.1|
        8|Security|ST|O|1|40||2.3.1|
        9|Message Type|MSG|R|1|7|0076|2.3.1|
        10|Message Control ID|ST|R|1|20||2.3.1|
        11|Processing ID|PT|R|1|3||2.3.1|
        12|Version ID|VID|R|1|60|0104|2.3.1|
        13|Sequence Number|NM|O|1|15||2.3.1|
        14|Continuation Pointer|ST|O|1|180||2.3.1|
        15|Accept Acknowledgment Type|ID|O|1|2|0155|2.3.1|
        16|Application Acknowledgment Type|ID|O|1|2|0155|2.3.1|
        17|Country Code|ID|O|1|2||2.3.1|
        18|Character Set|ID|O|*|16|0211|2.3.1|
        19|Principal Language Of Message|CE|O|1|60||2.3.1|
        20|Alternate Character Set Handling Scheme|ID|O|1|20|0356|2.3.1|
        """,
        "EVN": """
        1|Event Type Code|ID|B|1|3|0003|2.3.1|2.3.1
        2|Recorded Date/Time|TS|R|1|26||2.3.1|
        3|Date/Time Planned Event|TS|O|1|26||2.3.1|
        4|Event Reason Code|IS|O|1|3|0062|2.3.1|
        5|Operator ID|XCN|O|*|60|0188|2.3.1|
        6|Event Occurred|TS|O|1|26||2.3.1|
        """,
        "PID": """
        1|Set ID - PID|SI|O|1|4||2.3.1|
        2|Patient ID|CX|B|1|20||2.3.1|2.3.1
        3|Patient Identifier List|CX|R|*|20||2.3.1|
        4|Alternate Patient ID - PID|CX|B|*|20||2.3.1|2.3.1
        5|Patient Name|XPN|R|*|48||2.3.1|
        6|Mothers Maiden Name|XPN|O|*|48||2.3.1|
        7|Date/Time Of Birth|TS|O|1|26||2.3.1|
        8|Sex|IS|O|1|1|0001|2.3.1|
        9|Patient Alias|XPN|O|*|48||2.3.1|2.4
        10|Race|CE|O|*|80|0005|2.3.1|
        11|Patient Address|XAD|O|*|106||2.3.1|
        12|County Code|IS|B|1|4|0289|2.3.1|2.3.1
        13|Phone Number - Home|XTN|O|*|40||2.3.1|
        14|Phone Number - Business|XTN|O|*|40||2.3.1|
        15|Primary Language|CE|O|1|60|0296|2.3.1|
        16|Marital Status|CE|O|1|80|0002|2.3.1|
        17|Religion|CE|O|1|80|0006|2.3.1|
        18|Patient Account Number|CX|O|1|20||2.3.1|
        19|SSN Number - Patient|ST|B|1|16||2.3.1|2.3.1
        20|Driver's License Number - Patient|DLN|O|1|25||2.3.1|2.5
        21|Mother's Identifier|CX|O|*|20||2.3.1|
        22|Ethnic Group|CE|O|*|80|0189|2.3.1|
        23|Birth Place|ST|O|1|60||2.3.1|
        24|Multiple Birth Indicator|ID|O|1|1|0136|2.3.1|
        25|Birth Order|NM|O|1|2||2.3.1|
        26|Citizenship|CE|O|*|80|0171|2.3.1|
        27|Veterans Military Status|CE|O|1|60|0172|2.3.1|
        28|Nationality|CE|O|1|80|0212|2.3.1|2.4
        29|Patient Death Date and Time|TS|O|1|26||2.3.1|
        30|Patient Death Indicator|ID|O|1|1|0136|2.3.1|
        """,
        "PD1": """
        1|Living Dependency|IS|O|*|2|0223|2.3.1|
        2|Living Arrangement|IS|O|1|2|0220|2.3.1|
        3|Patient Primary Facility|XON|O|*|90||2.3.1|
        4|Patient Primary Care Provider Name & ID No.|XCN|O|*|90||2.3.1|2.4
        5|Student Indicator|IS|O|1|2|0231|2.3.1|
        6|Handicap|IS|O|1|2|0295|2.3.1|
        7|Living Will|IS|O|1|2|0315|2.3.1|
        8|Organ Donor|IS|O|1|2|0316|2.3.1|
        9|Separate Bill|ID|O|1|1|0136|2.3.1|
        10|Duplicate Patient|CX|O|*|20||2.3.1|
        11|Publicity Code|CE|O|1|80|0215|2.3.1|
        12|Protection Indicator|ID|O|1|1|0136|2.3.1|2.6
        """,
        "NK1": """
        1|Set ID - NK1|SI|R|1|4||2.3.1|
        2|Name|XPN|O|*|48||2.3.1|
        3|Relationship|CE|O|1|60|0063|2.3.1|
        4|Address|XAD|O|*|106||2.3.1|
        5|Phone Number|XTN|O|*|40||2.3.1|
        6|Business Phone Number|XTN|O|*|40||2.3.1|
        7|Contact Role|CE|O|1|200|0131|2.3.1|
        8|Start Date|DT|O|1|8||2.3.1|
        9|End Date|DT|O|1|8||2.3.1|
        10|Next of Kin / Associated Parties Job Title|ST|O|1|60||2.3.1|
        11|Next of Kin / Associated Parties Job Code/Class|JCC|O|1|20|0327|2.3.1|
        12|Next of Kin / Associated Parties Employee Number|CX|O|1|20||2.3.1|
        13|Organization Name - NK1|XON|O|*|90||2.3.1|
        14|Marital Status|CE|O|1|80|0002|2.3.1|
        15|Sex|IS|O|1|1|0001|2.3.1|
        16|Date/Time Of Birth|TS|O|1|26||2.3.1|
        17|Living Dependency|IS|O|*|2|0223|2.3.1|
        18|Ambulatory Status|IS|O|*|2|0009|2.3.1|
        19|Citizenship|CE|O|*|80|0171|2.3.1|
        20|Primary Language|CE|O|1|60|0296|2.3.1|
        21|Living Arrangement|IS|O|1|2|0220|2.3.1|
        22|Publicity Code|CE|O|1|80|0215|2.3.1|
        23|Protection Indicator|ID|O|1|1|0136|2.3.1|
        24|Student Indicator|IS|O|1|2|0231|2.3.1|
        25|Religion|CE|O|1|80|0006|2.3.1|
        26|Mothers Maiden Name|XPN|O|*|48||2.3.1|
        27|Nationality|CE|O|1|80|0212|2.3.1|
        28|Ethnic Group|CE|O|*|80|0189|2.3.1|
        29|Contact Reason|CE|O|*|80|0222|2.3.1|
        30|Contact Persons Name|XPN|O|*|48||2.3.1|
        31|Contact Persons Telephone Number|XTN|O|*|40||2.3.1|
        32|Contact Persons Address|XAD|O|*|106||2.3.1|
        33|Next of Kin/Associated Partys Identifiers|CX|O|*|32||2.3.1|
        34|Job Status|IS|O|1|2|0311|2.3.1|
        35|Race|CE|O|*|80|0005|2.3.1|
        36|Handicap|IS|O|1|2|0295|2.3.1|
        37|Contact Person Social Security Number|ST|O|1|16||2.3.1|
        """,
        "PV1": """
        1|Set ID - PV1|SI|O|1|4||2.3.1|
        2|Patient Class|IS|R|1|1|0004|2.3.1|
        3|Assigned Patient Location|PL|O|1|80||2.3.1|
        4|Admission Type|IS|O|1|2|0007|2.3.1|
        5|Preadmit Number|CX|O|1|20||2.3.1|
        6|Prior Patient Location|PL|O|1|80||2.3.1|
        7|Attending Doctor|XCN|O|*|60|0010|2.3.1|
        8|Referring Doctor|XCN|O|*|60|0010|2.3.1|
        9|Consulting Doctor|XCN|O|*|60|0010|2.3.1|2.4
        10|Hospital Service|IS|O|1|3|0069|2.3.1|
        11|Temporary Location|PL|O|1|80||2.3.1|
        12|Preadmit Test Indicator|IS|O|1|2|0087|2.3.1|
        13|Re-admission Indicator|IS|O|1|2|0092|2.3.1|
        14|Admit Source|IS|O|1|3|0023|2.3.1|
        15|Ambulatory Status|IS|O|*|2|0009|2.3.1|
        16|VIP Indicator|IS|O|1|2|0099|2.3.1|
        17|Admitting Doctor|XCN|O|*|60|0010|2.3.1|
        18|Patient Type|IS|O|1|2|0018|2.3.1|
        19|Visit Number|CX|O|1|20||2.3.1|
        20|Financial Class|FC|O|*|50|0064|2.3.1|
        21|Charge Price Indicator|IS|O|1|2|0032|2.3.1|
        22|Courtesy Code|IS|O|1|2|0045|2.3.1|
        23|Credit Rating|IS|O|1|2|0046|2.3.1|
        24|Contract Code|IS|O|*|2|0044|2.3.1|
        25|Contract Effective Date|DT|O|*|8||2.3.1|
        26|Contract Amount|NM|O|*|12||2.3.1|
        27|Contract Period|NM|O|*|3||2.3.1|
        28|Interest Code|IS|O|1|2|0073|2.3.1|
        29|Transfer to Bad Debt Code|IS|O|1|1|0110|2.3.1|
        30|Transfer to Bad Debt Date|DT|O|1|8||2.3.1|
        31|Bad Debt Agency Code|IS|O|1|10|0021|2.3.1|
        32|Bad Debt Transfer Amount|NM|O|1|12||2.3.1|
        33|Bad Debt Recovery Amount|NM|O|1|12||2.3.1|
        34|Delete Account Indicator|IS|O|1|1|0111|2.3.1|
        35|Delete Account Date|DT|O|1|8||2.3.1|
        36|Discharge Disposition|IS|O|1|3|0112|2.3.1|
        37|Discharged to Location|DLD|O|1|25|0113|2.3.1|
        38|Diet Type|CE|O|1|80|0114|2.3.1|
        39|Servicing Facility|IS|O|1|2|0115|2.3.1|
        40|Bed Status|IS|B|1|1|0116|2.3.1|2.3.1
        41|Account Status|IS|O|1|2|0117|2.3.1|
        42|Pending Location|PL|O|1|80||2.3.1|
        43|Prior Temporary Location|PL|O|1|80||2.3.1|
        44|Admit Date/Time|TS|O|1|26||2.3.1|
        45|Discharge Date/Time|TS|O|1|26||2.3.1|
        46|Current Patient Balance|NM|O|1|12||2.3.1|
        47|Total Charges|NM|O|1|12||2.3.1|
        48|Total Adjustments|NM|O|1|12||2.3.1|
        49|Total Payments|NM|O|1|12||2.3.1|
        50|Alternate Visit ID|CX|O|1|20|0203|2.3.1|
        51|Visit Indicator|IS|O|1|1|0326|2.3.1|
        52|Other Healthcare Provider|XCN|O|*|60|0010|2.3.1|2.4
        """,
        "PV2": """
        1|Prior Pending Location|PL|C|1|80||2.3.1|
        2|Accommodation Code|CE|O|1|60|0129|2.3.1|
        3|Admit Reason|CE|O|1|60||2.3.1|
        4|Transfer Reason|CE|O|1|60||2.3.1|
        5|Patient Valuables|ST|O|*|25||2.3.1|
        6|Patient Valuables Location|ST|O|1|25||2.3.1|
        7|Visit User Code|IS|O|1|2|0130|2.3.1|
        8|Expected Admit Date/Time|TS|O|1|26||2.3.1|
        9|Expected Discharge Date/Time|TS|O|1|26||2.3.1|
        10|Estimated Length of Inpatient Stay|NM|O|1|3||2.3.1|
        11|Actual Length of Inpatient Stay|NM|O|1|3||2.3.1|
        12|Visit Description|ST|O|1|50||2.3.1|
        13|Referral Source Code|XCN|O|*|90||2.3.1|
        14|Previous Service Date|DT|O|1|8||2.3.1|
        15|Employment Illness Related Indicator|ID|O|1|1|0136|2.3.1|
        16|Purge Status Code|IS|O|1|1|0213|2.3.1|
        17|Purge Status Date|DT|O|1|8||2.3.1|
        18|Special Program Code|IS|O|1|2|0214|2.3.1|
        19|Retention Indicator|ID|O|1|1|0136|2.3.1|
        20|Expected Number of Insurance Plans|NM|O|1|1||2.3.1|
        21|Visit Publicity Code|IS|O|1|1|0215|2.3.1|
        22|Visit Protection Indicator|ID|O|1|1|0136|2.3.1|2.6
        23|Clinic Organization Name|XON|O|*|90||2.3.1|
        24|Patient Status Code|IS|O|1|2|0216|2.3.1|
        25|Visit Priority Code|IS|O|1|1|0217|2.3.1|
        26|Previous Treatment Date|DT|O|1|8||2.3.1|
        27|Expected Discharge Disposition|IS|O|1|2|0112|2.3.1|
        28|Signature on File Date|DT|O|1|8||2.3.1|
        29|First Similar Illness Date|DT|O|1|8||2.3.1|
        30|Patient Charge Adjustment Code|CE|O|1|80|0218|2.3.1|
        31|Recurring Service Code|IS|O|1|2|0219|2.3.1|
        32|Billing Media Code|ID|O|1|1|0136|2.3.1|
        33|Expected Surgery Date & Time|TS|O|1|26||2.3.1|
        34|Military Partnership Code|ID|O|1|1|0136|2.3.1|
        35|Military Non-Availability Code|ID|O|1|1|0136|2.3.1|
        36|Newborn Baby Indicator|ID|O|1|1|0136|2.3.1|
        37|Baby Detained Indicator|ID|O|1|1|0136|2.3.1|
        """,
        "AL1": """
        1|Set ID - AL1|SI|R|1|4||2.3.1|
        2|Allergy Type|IS|O|1|2|0127|2.3.1|
        3|Allergy Code/Mnemonic/Description|CE|R|1|60||2.3.1|
        4|Allergy Severity|IS|O|1|2|0128|2.3.1|
        5|Allergy Reaction|ST|O|*|15||2.3.1|
        6|Identification Date|DT|O|1|8||2.3.1|2.4
        """,
        "DG1": """
        1|Set ID - DG1|SI|R|1|4||2.3.1|
        2|Diagnosis Coding Method|ID|B|1|2|0053|2.3.1|2.3.1
        3|Diagnosis Code - DG1|CE|O|1|60|0051|2.3.1|
        4|Diagnosis Description|ST|B|1|40||2.3.1|2.3.1
        5|Diagnosis Date/Time|TS|O|1|26||2.3.1|
        6|Diagnosis Type|IS|R|1|2|0052|2.3.1|
        7|Major Diagnostic Category|CE|B|1|60|0118|2.3.1|2.3.1
        8|Diagnostic Related Group|CE|B|1|60|0055|2.3.1|2.3.1
        9|DRG Approval Indicator|ID|B|1|1|0136|2.3.1|2.3.1
        10|DRG Grouper Review Code|IS|B|1|2|0056|2.3.1|2.3.1
        11|Outlier Type|CE|B|1|60|0083|2.3.1|2.3.1
        12|Outlier Days|NM|B|1|3||2.3.1|2.3.1
        13|Outlier Cost|CP|B|1|12||2.3.1|2.3.1
        14|Grouper Version And Type|ST|B|1|4||2.3.1|2.3.1
        15|Diagnosis Priority|ID|O|1|2|0359|2.3.1|
        16|Diagnosing Clinician|XCN|O|*|60||2.3.1|
        17|Diagnosis Classification|IS|O|1|3|0228|2.3.1|
        18|Confidential Indicator|ID|O|1|1|0136|2.3.1|
        19|Attestation Date/Time|TS|O|1|26||2.3.1|
        """,
        "OBR": """
        1|Set ID - OBR|SI|O|1|4||2.3.1|
        2|Placer Order Number|EI|C|1|22||2.3.1|
        3|Filler Order Number|EI|C|1|22||2.3.1|
        4|Universal Service ID|CE|R|1|200||2.3.1|
        5|Priority-OBR|ID|X|1|2||2.3.1|2.4
        6|Requested Date/time|TS|X|1|26||2.3.1|2.4
        7|Observation Date/Time #|TS|C|1|26||2.3.1|
        8|Observation End Date/Time #|TS|O|1|26||2.3.1|
        9|Collection Volume *|CQ|O|1|20||2.3.1|
        10|Collector Identifier *|XCN|O|*|60||2.3.1|
        11|Specimen Action Code *|ID|O|1|1|0065|2.3.1|
        12|Danger Code|CE|O|1|60||2.3.1|
        13|Relevant Clinical Info.|ST|O|1|300||2.3.1|
        14|Specimen Received Date/Time *|TS|C|1|26||2.3.1|2.5
        15|Specimen Source|SPS|O|1|300|0070|2.3.1|2.5
        16|Ordering Provider|XCN|O|*|120||2.3.1|
        17|Order Callback Phone Number|XTN|O|2|40||2.3.1|
        18|Placer Field 1|ST|O|1|60||2.3.1|
        19|Placer Field 2|ST|O|1|60||2.3.1|
        20|Filler Field 1 +|ST|O|1|60||2.3.1|
        21|Filler Field 2 +|ST|O|1|60||2.3.1|
        22|Results Rpt/Status Chng - Date/Time +|TS|C|1|26||2.3.1|
        23|Charge to Practice +|MOC|O|1|40||2.3.1|
        24|Diagnostic Serv Sect ID|ID|O|1|10|0074|2.3.1|
        25|Result Status +|ID|C|1|1|0123|2.3.1|
        26|Parent Result +|PRL|O|1|200||2.3.1|
        27|Quantity/Timing|TQ|O|*|200||2.3.1|2.5
        28|Result Copies To|XCN|O|5|150||2.3.1|
        29|Parent|EIP|O|1|200||2.3.1|
        30|Transportation Mode|ID|O|1|20|0124|2.3.1|
        31|Reason for Study|CE|O|*|300||2.3.1|
        32|Principal Result Interpreter +|NDL|O|1|200||2.3.1|2.6
        33|Assistant Result Interpreter +|NDL|O|*|200||2.3.1|2.6
        34|Technician +|NDL|O|*|200||2.3.1|2.6
        35|Transcriptionist +|NDL|O|*|200||2.3.1|2.6
        36|Scheduled Date/Time +|TS|O|1|26||2.3.1|
        37|Number of Sample Containers *|NM|O|1|4||2.3.1|
        38|Transport Logistics of Collected Sample *|CE|O|*|60||2.3.1|
        39|Collectors Comment *|CE|O|*|200||2.3.1|
        40|Transport Arrangement Responsibility|CE|O|1|60||2.3.1|
        41|Transport Arranged|ID|O|1|30|0224|2.3.1|
        42|Escort Required|ID|O|1|1|0225|2.3.1|
        43|Planned Patient Transport Comment|CE|O|*|200||2.3.1|
        44|Procedure Code|CE|O|1|80|0088|2.3.1|
        45|Procedure Code Modifier|CE|O|*|80|0340|2.3.1|
        """,
        "OBX": """
        1|Set ID - OBX|SI|O|1|4||2.3.1|
        2|Value Type|ID|C|1|3|0125|2.3.1|
        3|Observation Identifier|CE|R|1|80||2.3.1|
        4|Observation Sub-ID|ST|C|1|20||2.3.1|
        5|Observation Value|varies|C|*|65536||2.3.1|
        6|Units|CE|O|1|60||2.3.1|
        7|References Range|ST|O|1|60||2.3.1|
        8|Abnormal Flags|ID|O|5|5|0078|2.3.1|
        9|Probability|NM|O|5|5||2.3.1|
        10|Nature of Abnormal Test|ID|O|1|2|0080|2.3.1|
        11|Observation Result Status|ID|R|1|1|0085|2.3.1|
        12|Date Last Obs Normal Values|TS|O|1|26||2.3.1|
        13|User Defined Access Checks|ST|O|1|20||2.3.1|
        14|Date/Time of the Observation|TS|O|1|26||2.3.1|
        15|Producer's ID|CE|O|1|60||2.3.1|
        16|Responsible Observer|XCN|O|*|80||2.3.1|
        17|Observation Method|CE|O|*|60||2.3.1|
        """,
        "ORC": """
        1|Order Control|ID|R|1|2|0119|2.3.1|
        2|Placer Order Number|EI|C|1|22||2.3.1|
        3|Filler Order Number|EI|C|1|22||2.3.1|
        4|Placer Group Number|EI|O|1|22||2.3.1|
        5|Order Status|ID|O|1|2|0038|2.3.1|
        6|Response Flag|ID|O|1|1|0121|2.3.1|
        7|Quantity/Timing|TQ|O|1|200||2.3.1|2.5
        8|Parent|EIP|O|1|200||2.3.1|
        9|Date/Time of Transaction|TS|O|1|26||2.3.1|
        10|Entered By|XCN|O|*|120||2.3.1|
        11|Verified By|XCN|O|*|120||2.3.1|
        12|Ordering Provider|XCN|O|*|120||2.3.1|
        13|Enterers Location|PL|O|1|80||2.3.1|
        14|Call Back Phone Number|XTN|O|2|40||2.3.1|
        15|Order Effective Date/Time|TS|O|1|26||2.3.1|
        16|Order Control Code Reason|CE|O|1|200||2.3.1|
        17|Entering Organization|CE|O|1|60||2.3.1|
        18|Entering Device|CE|O|1|60||2.3.1|
        19|Action By|XCN|O|*|120||2.3.1|
        20|Advanced Beneficiary Notice Code|CE|O|1|40|0339|2.3.1|
        21|Ordering Facility Name|XON|O|*|60||2.3.1|
        22|Ordering Facility Address|XAD|O|*|106||2.3.1|
        23|Ordering Facility Phone Number|XTN|O|*|48||2.3.1|
        24|Ordering Provider Address|XAD|O|*|106||2.3.1|
        """,
        "NTE": """
        1|Set ID - NTE|SI|O|1|4||2.3.1|
        2|Source of Comment|ID|O|1|8|0105|2.3.1|
        3|Comment|FT|O|*|65536||2.3.1|
        4|Comment Type|CE|O|1|60|0364|2.3.1|
        """,
        "IN1": """
        1|Set ID - IN1|SI|R|1|4||2.3.1|
        2|Insurance Plan ID|CE|R|1|60|0072|2.3.1|
        3|Insurance Company ID|CX|R|*|59||2.3.1|
        4|Insurance Company Name|XON|O|*|130||2.3.1|
        5|Insurance Company Address|XAD|O|*|106||2.3.1|
        6|Insurance Co Contact Person|XPN|O|*|48||2.3.1|
        7|Insurance Co Phone Number|XTN|O|*|40||2.3.1|
        8|Group Number|ST|O|1|12||2.3.1|
        9|Group Name|XON|O|*|130||2.3.1|
        10|Insureds Group Emp ID|CX|O|*|12||2.3.1|
        11|Insureds Group Emp Name|XON|O|*|130||2.3.1|
        12|Plan Effective Date|DT|O|1|8||2.3.1|
        13|Plan Expiration Date|DT|O|1|8||2.3.1|
        14|Authorization Information|AUI|O|1|55||2.3.1|
        15|Plan Type|IS|O|1|3|0086|2.3.1|
        16|Name Of Insured|XPN|O|*|48||2.3.1|
        17|Insureds Relationship To Patient|CE|O|1|80|0063|2.3.1|
        18|Insureds Date Of Birth|TS|O|1|26||2.3.1|
        19|Insureds Address|XAD|O|*|106||2.3.1|
        20|Assignment Of Benefits|IS|O|1|2|0135|2.3.1|
        21|Coordination Of Benefits|IS|O|1|2|0173|2.3.1|
        22|Coord Of Ben. Priority|ST|O|1|2||2.3.1|
        23|Notice Of Admission Flag|ID|O|1|1|0136|2.3.1|
        24|Notice Of Admission Date|DT|O|1|8||2.3.1|
        25|Report Of Eligibility Flag|ID|O|1|1|0136|2.3.1|
        26|Report Of Eligibility Date|DT|O|1|8||2.3.1|
        27|Release Information Code|IS|O|1|2|0093|2.3.1|
        28|Pre-Admit Cert (PAC)|ST|O|1|15||2.3.1|
        29|Verification Date/Time|TS|O|1|26||2.3.1|
        30|Verification By|XCN|O|*|60||2.3.1|
        31|Type Of Agreement Code|IS|O|1|2|0098|2.3.1|
        32|Billing Status|IS|O|1|2|0022|2.3.1|
        33|Lifetime Reserve Days|NM|O|1|4||2.3.1|
        34|Delay Before L.R. Day|NM|O|1|4||2.3.1|
        35|Company Plan Code|IS|O|1|8|0042|2.3.1|
        36|Policy Number|ST|O|1|15||2.3.1|
        37|Policy Deductible|CP|O|1|12||2.3.1|
        38|Policy Limit - Amount|CP|B|1|12||2.3.1|2.3.1
        39|Policy Limit - Days|NM|O|1|4||2.3.1|
        40|Room Rate - Semi-Private|CP|B|1|12||2.3.1|2.3.1
        41|Room Rate - Private|CP|B|1|12||2.3.1|2.3.1
        42|Insureds Employment Status|CE|O|1|60|0066|2.3.1|
        43|Insureds Sex|IS|O|1|1|0001|2.3.1|
        44|Insureds Employers Address|XAD|O|*|106||2.3.1|
        45|Verification Status|ST|O|1|2||2.3.1|
        46|Prior Insurance Plan ID|IS|O|1|8|0072|2.3.1|
        47|Coverage Type|IS|O|1|3|0309|2.3.1|
        48|Handicap|IS|O|1|2|0295|2.3.1|
        49|Insureds ID Number|CX|O|*|12||2.3.1|
        """,
        "GT1": """
        1|Set ID - GT1|SI|R|1|4||2.3.1|
        2|Guarantor Number|CX|O|*|59||2.3.1|
        3|Guarantor Name|XPN|R|*|48||2.3.1|
        4|Guarantor Spouse Name|XPN|O|*|48||2.3.1|
        5|Guarantor Address|XAD|O|*|106||2.3.1|
        6|Guarantor Ph Num-Home|XTN|O|*|40||2.3.1|
        7|Guarantor Ph Num-Business|XTN|O|*|40||2.3.1|
        8|Guarantor Date/Time Of Birth|TS|O|1|26||2.3.1|
        9|Guarantor Sex|IS|O|1|1|0001|2.3.1|
        10|Guarantor Type|IS|O|1|2|0068|2.3.1|
        11|Guarantor Relationship|CE|O|1|80|0063|2.3.1|
        12|Guarantor SSN|ST|O|1|11||2.3.1|
        13|Guarantor Date - Begin|DT|O|1|8||2.3.1|
        14|Guarantor Date - End|DT|O|1|8||2.3.1|
        15|Guarantor Priority|NM|O|1|2||2.3.1|
        16|Guarantor Employer Name|XPN|O|*|130||2.3.1|
        17|Guarantor Employer Address|XAD|O|*|106||2.3.1|
        18|Guarantor Employer Phone Number|XTN|O|*|40||2.3.1|
        19|Guarantor Employee ID Number|CX|O|*|20||2.3.1|
        20|Guarantor Employment Status|IS|O|1|2|0066|2.3.1|
        21|Guarantor Organization Name|XON|O|*|130||2.3.1|
        22|Guarantor Billing Hold Flag|ID|O|1|1|0136|2.3.1|
        23|Guarantor Credit Rating Code|CE|O|1|80|0341|2.3.1|
        24|Guarantor Death Date And Time|TS|O|1|26||2.3.1|
        25|Guarantor Death Flag|ID|O|1|1|0136|2.3.1|
        26|Guarantor Charge Adjustment Code|CE|O|1|80|0218|2.3.1|
        27|Guarantor Household Annual Income|CP|O|1|10||2.3.1|
        28|Guarantor Household Size|NM|O|1|3||2.3.1|
        29|Guarantor Employer ID Number|CX|O|*|20||2.3.1|
        30|Guarantor Marital Status Code|CE|O|1|80|0002|2.3.1|
        31|Guarantor Hire Effective Date|DT|O|1|8||2.3.1|
        32|Employment Stop Date|DT|O|1|8||2.3.1|
        33|Living Dependency|IS|O|1|2|0223|2.3.1|
        34|Ambulatory Status|IS|O|*|2|0009|2.3.1|
        35|Citizenship|CE|O|*|80|0171|2.3.1|
        36|Primary Language|CE|O|1|60|0296|2.3.1|
        37|Living Arrangement|IS|O|1|2|0220|2.3.1|
        38|Publicity Code|CE|O|1|80|0215|2.3.1|
        39|Protection Indicator|ID|O|1|1|0136|2.3.1|
        40|Student Indicator|IS|O|1|2|0231|2.3.1|
        41|Religion|CE|O|1|80|0006|2.3.1|
        42|Mothers Maiden Name|XPN|O|*|48||2.3.1|
        43|Nationality|CE|O|1|80|0212|2.3.1|
        44|Ethnic Group|CE|O|*|80|0189|2.3.1|
        45|Contact Persons Name|XPN|O|*|48||2.3.1|
        46|Contact Persons Telephone Number|XTN|O|*|40||2.3.1|
        47|Contact Reason|CE|O|1|80|0222|2.3.1|
        48|Contact Relationship|IS|O|1|2|0063|2.3.1|
        49|Job Title|ST|O|1|20||2.3.1|
        50|Job Code/Class|JCC|O|1|20|0327|2.3.1|
        51|Guarantor Employers Organization Name|XON|O|*|130||2.3.1|
        52|Handicap|IS|O|1|2|0295|2.3.1|
        53|Job Status|IS|O|1|2|0311|2.3.1|
        54|Guarantor Financial Class|FC|O|1|50|0064|2.3.1|
        55|Guarantor Race|CE|O|*|80|0005|2.3.1|
        """,
        "MSA": """
        1|Acknowledgement Code|ID|R|1|2|0008|2.3.1|
        2|Message Control ID|ST|R|1|20||2.3.1|
        3|Text Message|ST|O|1|80||2.3.1|2.5
        4|Expected Sequence Number|NM|O|1|15||2.3.1|
        5|Delayed Acknowledgment Type|ID|B|1|1|0102|2.3.1|2.3.1
        6|Error Condition|CE|O|1|100||2.3.1|2.5
        """,
        "ERR": """
        1|Error Code and Location|ELD|R|*|80||2.3.1|2.5
        """,
        "QRD": """
        1|Query Date/Time|TS|R|1|26||2.3.1|
        2|Query Format Code|ID|R|1|1|0106|2.3.1|
        3|Query Priority|ID|R|1|1|0091|2.3.1|
        4|Query ID|ST|R|1|10||2.3.1|
        5|Deferred Response Type|ID|O|1|1|0107|2.3.1|
        6|Deferred Response Date/Time|TS|O|1|26||2.3.1|
        7|Quantity Limited Request|CQ|R|1|10|0126|2.3.1|
        8|Who Subject Filter|XCN|R|*|60||2.3.1|
        9|What Subject Filter|CE|R|*|60|0048|2.3.1|
        10|What Department Data Code|CE|R|*|60||2.3.1|
        11|What Data Code Value Qual.|VR|O|*|20||2.3.1|
        12|Query Results Level|ID|O|1|1|0108|2.3.1|
        """,
        "QRF": """
        1|Where Subject Filter|ST|R|*|20||2.3.1|
        2|When Data Start Date/Time|TS|O|1|26||2.3.1|2.4
        3|When Data End Date/Time|TS|O|1|26||2.3.1|2.4
        4|What User Qualifier|ST|O|*|60||2.3.1|
        5|Other QRY Subject Filter|ST|O|*|60||2.3.1|
        6|Which Date/Time Qualifier|ID|O|*|12|0156|2.3.1|
        7|Which Date/Time Status Qualifier|ID|O|*|12|0157|2.3.1|
        8|Date/Time Selection Qualifier|ID|O|*|12|0158|2.3.1|
        9|When Quantity/Timing Qualifier|TQ|O|1|60||2.3.1|2.6
        """,
        "QAK": """
        1|Query Tag|ST|C|1|32||2.3.1|
        2|Query Response Status|ID|O|1|2|0208|2.3.1|
        """,
        "DSC": """
        1|Continuation Pointer|ST|O|1|180||2.3.1|
        """,
    ]
    static let types2_3_1: [String: String] = [
        "AUI": """
        """,
        "CE": """
        identifier|ST|O|
        text|ST|O|
        name of coding system|ST|O|
        alternate identifier|ST|O|
        alternate text|ST|O|
        name of alternate coding system|ST|O|
        """,
        "CNE": """
        """,
        "CP": """
        price|MO|O|
        price type|ID|O|
        from value|NM|O|
        to value|NM|O|
        range units|CE|O|
        range type|ID|O|
        """,
        "CQ": """
        quantity|NM|O|
        units|CE|O|
        """,
        "CWE": """
        """,
        "CX": """
        ID|ST|O|
        check digit|NM|O|
        code identifying the check digit scheme employed|ID|O|
        assigning authority|HD|O|
        identifier type code|IS|O|
        assigning facility|HD|O|
        """,
        "DLD": """
        """,
        "DLN": """
        Driver's License Number|ST|O|
        Issuing State, province, country|IS|O|
        expiration date|DT|O|
        """,
        "DR": """
        range start date/time|TS|O|
        range end date/time|TS|O|
        """,
        "DT": "",
        "ED": """
        source application|HD|O|
        type of data|ID|O|
        data subtype|ID|O|
        encoding|ID|O|
        data|ST|O|
        """,
        "EI": """
        entity identifier|ST|O|
        namespace ID|IS|O|
        universal ID|ST|O|
        universal ID type|ID|O|
        """,
        "EIP": """
        """,
        "ELD": """
        """,
        "FC": """
        Financial Class|IS|O|
        Effective Date|TS|O|
        """,
        "FN": """
        """,
        "FT": "",
        "HD": """
        namespace ID|IS|O|
        universal ID|ST|O|
        universal ID type|ID|O|
        """,
        "ID": "",
        "IS": "",
        "JCC": """
        job code|IS|O|
        job class|IS|O|
        """,
        "MO": """
        quantity|NM|O|
        denomination|ID|O|
        """,
        "MOC": """
        """,
        "MSG": """
        """,
        "NDL": """
        """,
        "NM": "",
        "PL": """
        point of care|IS|O|
        room|IS|O|
        bed|IS|O|
        facility (HD)|HD|O|
        location status|IS|O|
        person location type|IS|O|
        building|IS|O|
        floor|IS|O|
        Location description|ST|O|
        """,
        "PRL": """
        """,
        "PT": """
        processing ID|ID|O|
        processing mode|ID|O|
        """,
        "QIP": """
        field name|ST|O|
        value1&value2&value3|ST|O|
        """,
        "QSC": """
        segment field name|ST|O|
        relational operator|ID|O|
        Value|ST|O|
        relational conjunction|ID|O|
        """,
        "RI": """
        repeat pattern|IS|O|
        explicit time interval|ST|O|
        """,
        "RP": """
        pointer|ST|O|
        application ID|HD|O|
        type of data|ID|O|
        subtype|ID|O|
        """,
        "SCV": """
        parameter class|IS|O|
        parameter value|IS|O|
        """,
        "SI": "",
        "SN": """
        comparator|ST|O|
        num1|NM|O|
        separator or suffix|ST|O|
        num2|NM|O|
        """,
        "SPS": """
        """,
        "ST": "",
        "TM": "",
        "TQ": """
        quantity|CQ|O|
        interval|RI|O|
        duration|ST|O|
        start date/time|TS|O|
        end date/time|TS|O|
        priority|ST|O|
        condition|ST|O|
        text|ST|O|
        conjunction|ST|O|
        order sequencing|OSD|O|
        """,
        "TS": """
        time of an event|ST|O|
        degree of precision|ST|O|
        """,
        "TX": "",
        "VID": """
        """,
        "VR": """
        """,
        "XAD": """
        street address|ST|O|
        other designation|ST|O|
        city|ST|O|
        state or province|ST|O|
        zip or postal code|ST|O|
        country|ID|O|
        address type|ID|O|
        other geographic designation|ST|O|
        county/parish code|IS|O|
        census tract|IS|O|
        """,
        "XCN": """
        ID number (ST)|ST|O|
        family+last name|FN|O|
        given name|ST|O|
        middle initial or name|ST|O|
        suffix (e.g., JR or III)|ST|O|
        prefix (e.g., DR)|ST|O|
        degree (e.g., MD)|IS|O|
        source table|IS|O|
        assigning authority|HD|O|
        name type code|ID|O|
        identifier check digit|ST|O|
        code identifying the check digit scheme employed|ID|O|
        identifier type code|IS|O|
        assigning facility|HD|O|
        """,
        "XON": """
        organization name|ST|O|
        organization name type code|IS|O|
        ID number (NM)|NM|O|
        check digit|NM|O|
        code identifying the check digit scheme employed|ID|O|
        assigning authority|HD|O|
        identifier type code|IS|O|
        assigning facility ID|HD|O|
        """,
        "XPN": """
        family+last name|FN|O|
        given name|ST|O|
        middle initial or name|ST|O|
        suffix (e.g., JR or III)|ST|O|
        prefix (e.g., DR)|ST|O|
        degree (e.g., MD)|IS|O|
        name type code|ID|O|
        Name Representation code|ID|O|
        """,
        "XTN": """
        [(999)] 999-9999 [X99999][C any text]|TN|O|
        telecommunication use code|ID|O|
        telecommunication equipment type (ID)|ID|O|
        Email address|ST|O|
        Country Code|NM|O|
        Area/city code|NM|O|
        Phone number|NM|O|
        Extension|NM|O|
        any text|ST|O|
        """,
        "OSD": """
        """,
        "TN": "",
    ]
    static let sets2_3_1: [String: Set<String>] = [
        "0001": ["F", "M", "O", "U"],
        "0004": ["E", "I", "O", "P", "R", "B"],
        "0003": ["X01", "A01", "A02", "A03", "A04", "A05", "A06", "A07", "A08", "A09", "A10", "A11", "A12", "A13", "A14", "A15", "A16", "A17", "A18", "A19", "A20", "A21", "A22", "A23", "A24", "A25", "A26", "A27", "A28", "A29", "A30", "A31", "A32", "A33", "A34", "A35", "A36", "A37", "A38", "A39", "A40", "A41", "A42", "A43", "A44", "A45", "A46", "A47", "A48", "A49", "A50", "A51", "C01", "C02", "C03", "C04", "C05", "C06", "C07", "C08", "C09", "C10", "C11", "C12", "CNQ", "I01", "I02", "I03", "I04", "I05", "I06", "I07", "I08", "I09", "I10", "I11", "I12", "I13", "I14", "I15", "M01", "M02", "M03", "varies", "M04", "M05", "M06", "M07", "M08", "M09", "M10", "M11", "O01", "O02", "P01", "P02", "P03", "P04", "P05", "P06", "P07", "P08", "P09", "PC1", "PC2", "PC3", "PC4", "PC5", "PC6", "PC7", "PC8", "PC9", "PCA", "PCB", "PCC", "PCD", "PCE", "PCF", "PCG", "PCH", "PCJ", "PCK", "PCL", "Q01", "Q02", "Q03", "Q04", "Q05", "Q06", "Q07", "Q08", "Q09", "R01", "R02", "R03", "R04", "R05", "R06", "R07", "R08", "R09", "RAR", "RDR", "RER", "RGR", "R0R", "ROR", "S01", "S02", "S03", "S04", "S05", "S06", "S07", "S08", "S09", "S10", "S11", "S12", "S13", "S14", "S15", "S16", "S17", "S18", "S19", "S20", "S21", "S22", "S23", "S24", "S25", "S26", "T01", "T02", "T03", "T04", "T05", "T06", "T07", "T08", "T09", "T10", "T11", "T12", "V01", "V02", "V03", "V04", "W01", "W02"],
        "0008": ["AA", "AE", "AR", "CA", "CE", "CR"],
        "0076": ["ACK", "ADR", "ARD", "ADT", "BAR", "CRM", "CSU", "DFT", "DOC", "DSR", "EDR", "EQQ", "ERP", "MCF", "MDM", "MFN", "MFK", "MFD", "MFQ", "MFR", "NMD", "NMQ", "NMR", "ORF", "ORM", "ORR", "ORU", "OSQ", "OSR", "PEX", "PGL", "PIN", "PPG", "PPP", "PPR", "PPT", "PPV", "PRR", "PTR", "QCK", "QRY", "RAR", "RAS", "RCI", "RCL", "RDE", "RDR", "RDS", "REF", "RER", "RGV", "RGR", "ROR", "RPA", "RPI", "RPL", "RPR", "RQA", "RQC", "RQI", "RQP", "RQQ", "RRA", "RRD", "RRE", "RRG", "RRI", "SIU", "SPQ", "SQM", "SQR", "SRM", "SRR", "SUR", "TBR", "UDM", "VQQ", "VXQ", "VXX", "VXR", "VXU"],
        "0103": ["D", "P", "T"],
        "0207": ["A", "R", "I", "T", "not present"],
        "0085": ["C", "D", "F", "I", "N", "O", "P", "R", "S", "X", "U", "W"],
        "0078": ["L", "H", "LL", "HH", "<", ">", "N", "A", "AA", "null", "U", "D", "B", "W", "S", "R", "I", "MS", "VS"],
        "0119": ["NW", "OK", "UA", "CA", "OC", "CR", "UC", "DC", "OD", "DR", "UD", "HD", "OH", "UH", "HR", "RL", "OE", "OR", "UR", "RP", "RU", "RO", "RQ", "UM", "PA", "CH", "XO", "XX", "UX", "XR", "DE", "RE", "RR", "SR", "SS", "SC", "SN", "NA", "CN", "RF", "AF", "DF", "FU", "OF", "UF", "LI", "UN"],
        "0357": ["0", "100", "101", "102", "103", "200", "201", "202", "203", "204", "205", "206", "207"],
        "0125": ["AD", "CE", "CF", "CK", "CN", "CP", "CX", "DT", "ED", "FT", "MO", "NM", "PN", "RP", "SN", "ST", "TM", "TN", "TS", "TX", "XAD", "XCN", "XON", "XPN", "XTN"],
        "0155": ["AL", "NE", "ER", "SU"],
        "0206": ["A", "D", "U"],
    ]
}
