// HL7 attribute facts: https://www.hl7.eu/HL7v2x/v251/
// Independent Swift representation; no HL7kit implementation code.
extension HL7Tables {
    static let v2_5_1: [String: String] = [
        "MSH": """
        1|Field Separator|ST|R|1|1||2.3.1|
        2|Encoding Characters|ST|R|1|4||2.3.1|
        3|Sending Application|HD|O|1|227|0361|2.3.1|
        4|Sending Facility|HD|O|1|227|0362|2.3.1|
        5|Receiving Application|HD|O|1|227|0361|2.3.1|
        6|Receiving Facility|HD|O|1|227|0362|2.3.1|
        7|Date/Time Of Message|TS|R|1|26||2.3.1|
        8|Security|ST|O|1|40||2.3.1|
        9|Message Type|MSG|R|1|15||2.3.1|
        10|Message Control ID|ST|R|1|20||2.3.1|
        11|Processing ID|PT|R|1|3||2.3.1|
        12|Version ID|VID|R|1|60||2.3.1|
        13|Sequence Number|NM|O|1|15||2.3.1|
        14|Continuation Pointer|ST|O|1|180||2.3.1|
        15|Accept Acknowledgment Type|ID|O|1|2|0155|2.3.1|
        16|Application Acknowledgment Type|ID|O|1|2|0155|2.3.1|
        17|Country Code|ID|O|1|3|0399|2.3.1|
        18|Character Set|ID|O|*|16|0211|2.3.1|
        19|Principal Language Of Message|CE|O|1|250||2.3.1|
        20|Alternate Character Set Handling Scheme|ID|O|1|20|0356|2.3.1|
        21|Message Profile Identifier|EI|O|*|427||2.4|
        """,
        "EVN": """
        1|Event Type Code|ID|B|1|3|0003|2.3.1|2.3.1
        2|Recorded Date/Time|TS|R|1|26||2.3.1|
        3|Date/Time Planned Event|TS|O|1|26||2.3.1|
        4|Event Reason Code|IS|O|1|3|0062|2.3.1|
        5|Operator ID|XCN|O|*|250|0188|2.3.1|
        6|Event Occurred|TS|O|1|26||2.3.1|
        7|Event Facility|HD|O|1|241||2.4|
        """,
        "PID": """
        1|Set ID - PID|SI|O|1|4||2.3.1|
        2|Patient ID|CX|B|1|20||2.3.1|2.3.1
        3|Patient Identifier List|CX|R|*|250||2.3.1|
        4|Alternate Patient ID - PID|CX|B|*|20||2.3.1|2.3.1
        5|Patient Name|XPN|R|*|250||2.3.1|
        6|Mother's Maiden Name|XPN|O|*|250||2.3.1|
        7|Date/Time of Birth|TS|O|1|26||2.3.1|
        8|Administrative Sex|IS|O|1|1|0001|2.3.1|
        9|Patient Alias|XPN|B|*|250||2.3.1|2.4
        10|Race|CE|O|*|250|0005|2.3.1|
        11|Patient Address|XAD|O|*|250||2.3.1|
        12|County Code|IS|B|1|4|0289|2.3.1|2.3.1
        13|Phone Number - Home|XTN|O|*|250||2.3.1|
        14|Phone Number - Business|XTN|O|*|250||2.3.1|
        15|Primary Language|CE|O|1|250|0296|2.3.1|
        16|Marital Status|CE|O|1|250|0002|2.3.1|
        17|Religion|CE|O|1|250|0006|2.3.1|
        18|Patient Account Number|CX|O|1|250||2.3.1|
        19|SSN Number - Patient|ST|B|1|16||2.3.1|2.3.1
        20|Driver's License Number - Patient|DLN|B|1|25||2.3.1|2.5
        21|Mother's Identifier|CX|O|*|250||2.3.1|
        22|Ethnic Group|CE|O|*|250|0189|2.3.1|
        23|Birth Place|ST|O|1|250||2.3.1|
        24|Multiple Birth Indicator|ID|O|1|1|0136|2.3.1|
        25|Birth Order|NM|O|1|2||2.3.1|
        26|Citizenship|CE|O|*|250|0171|2.3.1|
        27|Veterans Military Status|CE|O|1|250|0172|2.3.1|
        28|Nationality|CE|B|1|250|0212|2.3.1|2.4
        29|Patient Death Date and Time|TS|O|1|26||2.3.1|
        30|Patient Death Indicator|ID|O|1|1|0136|2.3.1|
        31|Identity Unknown Indicator|ID|O|1|1|0136|2.4|
        32|Identity Reliability Code|IS|O|*|20|0445|2.4|
        33|Last Update Date/Time|TS|O|1|26||2.4|
        34|Last Update Facility|HD|O|1|241||2.4|
        35|Species Code|CE|C|1|250|0446|2.4|
        36|Breed Code|CE|C|1|250|0447|2.4|
        37|Strain|ST|O|1|80||2.4|
        38|Production Class Code|CE|O|2|250|0429|2.4|
        39|Tribal Citizenship|CWE|O|*|250|0171|2.5|
        """,
        "PD1": """
        1|Living Dependency|IS|O|*|2|0223|2.3.1|
        2|Living Arrangement|IS|O|1|2|0220|2.3.1|
        3|Patient Primary Facility|XON|O|*|250||2.3.1|
        4|Patient Primary Care Provider Name & ID No.|XCN|B|*|250||2.3.1|2.4
        5|Student Indicator|IS|O|1|2|0231|2.3.1|
        6|Handicap|IS|O|1|2|0295|2.3.1|
        7|Living Will Code|IS|O|1|2|0315|2.3.1|
        8|Organ Donor Code|IS|O|1|2|0316|2.3.1|
        9|Separate Bill|ID|O|1|1|0136|2.3.1|
        10|Duplicate Patient|CX|O|*|250||2.3.1|
        11|Publicity Code|CE|O|1|250|0215|2.3.1|
        12|Protection Indicator|ID|O|1|1|0136|2.3.1|2.6
        13|Protection Indicator Effective Date|DT|O|1|8||2.4|2.6
        14|Place of Worship|XON|O|*|250||2.4|
        15|Advance Directive Code|CE|O|*|250|0435|2.4|
        16|Immunization Registry Status|IS|O|1|1|0441|2.4|
        17|Immunization Registry Status Effective Date|DT|O|1|8||2.4|
        18|Publicity Code Effective Date|DT|O|1|8||2.4|
        19|Military Branch|IS|O|1|5|0140|2.4|
        20|Military Rank/Grade|IS|O|1|2|0141|2.4|
        21|Military Status|IS|O|1|3|0142|2.4|
        """,
        "NK1": """
        1|Set ID - NK1|SI|R|1|4||2.3.1|
        2|Name|XPN|O|*|250||2.3.1|
        3|Relationship|CE|O|1|250|0063|2.3.1|
        4|Address|XAD|O|*|250||2.3.1|
        5|Phone Number|XTN|O|*|250||2.3.1|
        6|Business Phone Number|XTN|O|*|250||2.3.1|
        7|Contact Role|CE|O|1|250|0131|2.3.1|
        8|Start Date|DT|O|1|8||2.3.1|
        9|End Date|DT|O|1|8||2.3.1|
        10|Next of Kin / Associated Parties Job Title|ST|O|1|60||2.3.1|
        11|Next of Kin / Associated Parties Job Code/Class|JCC|O|1|20|0327|2.3.1|
        12|Next of Kin / Associated Parties Employee Number|CX|O|1|250||2.3.1|
        13|Organization Name - NK1|XON|O|*|250||2.3.1|
        14|Marital Status|CE|O|1|250|0002|2.3.1|
        15|Administrative Sex|IS|O|1|1|0001|2.3.1|
        16|Date/Time of Birth|TS|O|1|26||2.3.1|
        17|Living Dependency|IS|O|*|2|0223|2.3.1|
        18|Ambulatory Status|IS|O|*|2|0009|2.3.1|
        19|Citizenship|CE|O|*|250|0171|2.3.1|
        20|Primary Language|CE|O|1|250|0296|2.3.1|
        21|Living Arrangement|IS|O|1|2|0220|2.3.1|
        22|Publicity Code|CE|O|1|250|0215|2.3.1|
        23|Protection Indicator|ID|O|1|1|0136|2.3.1|
        24|Student Indicator|IS|O|1|2|0231|2.3.1|
        25|Religion|CE|O|1|250|0006|2.3.1|
        26|Mother's Maiden Name|XPN|O|*|250||2.3.1|
        27|Nationality|CE|O|1|250|0212|2.3.1|
        28|Ethnic Group|CE|O|*|250|0189|2.3.1|
        29|Contact Reason|CE|O|*|250|0222|2.3.1|
        30|Contact Person's Name|XPN|O|*|250||2.3.1|
        31|Contact Person's Telephone Number|XTN|O|*|250||2.3.1|
        32|Contact Person's Address|XAD|O|*|250||2.3.1|
        33|Next of Kin/Associated Party's Identifiers|CX|O|*|250||2.3.1|
        34|Job Status|IS|O|1|2|0311|2.3.1|
        35|Race|CE|O|*|250|0005|2.3.1|
        36|Handicap|IS|O|1|2|0295|2.3.1|
        37|Contact Person Social Security Number|ST|O|1|16||2.3.1|
        38|Next of Kin Birth Place|ST|O|1|250||2.5|
        39|VIP Indicator|IS|O|1|2|0099|2.5|
        """,
        "PV1": """
        1|Set ID - PV1|SI|O|1|4||2.3.1|
        2|Patient Class|IS|R|1|1|0004|2.3.1|
        3|Assigned Patient Location|PL|O|1|80||2.3.1|
        4|Admission Type|IS|O|1|2|0007|2.3.1|
        5|Preadmit Number|CX|O|1|250||2.3.1|
        6|Prior Patient Location|PL|O|1|80||2.3.1|
        7|Attending Doctor|XCN|O|*|250|0010|2.3.1|
        8|Referring Doctor|XCN|O|*|250|0010|2.3.1|
        9|Consulting Doctor|XCN|B|*|250|0010|2.3.1|2.4
        10|Hospital Service|IS|O|1|3|0069|2.3.1|
        11|Temporary Location|PL|O|1|80||2.3.1|
        12|Preadmit Test Indicator|IS|O|1|2|0087|2.3.1|
        13|Re-admission Indicator|IS|O|1|2|0092|2.3.1|
        14|Admit Source|IS|O|1|6|0023|2.3.1|
        15|Ambulatory Status|IS|O|*|2|0009|2.3.1|
        16|VIP Indicator|IS|O|1|2|0099|2.3.1|
        17|Admitting Doctor|XCN|O|*|250|0010|2.3.1|
        18|Patient Type|IS|O|1|2|0018|2.3.1|
        19|Visit Number|CX|O|1|250||2.3.1|
        20|Financial Class|FC|O|*|50|0064|2.3.1|
        21|Charge Price Indicator|IS|O|1|2|0032|2.3.1|
        22|Courtesy Code|IS|O|1|2|0045|2.3.1|
        23|Credit Rating|IS|O|1|2|0046|2.3.1|
        24|Contract Code|IS|O|*|2|0044|2.3.1|
        25|Contract Effective Date|DT|O|*|8||2.3.1|
        26|Contract Amount|NM|O|*|12||2.3.1|
        27|Contract Period|NM|O|*|3||2.3.1|
        28|Interest Code|IS|O|1|2|0073|2.3.1|
        29|Transfer to Bad Debt Code|IS|O|1|4|0110|2.3.1|
        30|Transfer to Bad Debt Date|DT|O|1|8||2.3.1|
        31|Bad Debt Agency Code|IS|O|1|10|0021|2.3.1|
        32|Bad Debt Transfer Amount|NM|O|1|12||2.3.1|
        33|Bad Debt Recovery Amount|NM|O|1|12||2.3.1|
        34|Delete Account Indicator|IS|O|1|1|0111|2.3.1|
        35|Delete Account Date|DT|O|1|8||2.3.1|
        36|Discharge Disposition|IS|O|1|3|0112|2.3.1|
        37|Discharged to Location|DLD|O|1|47|0113|2.3.1|
        38|Diet Type|CE|O|1|250|0114|2.3.1|
        39|Servicing Facility|IS|O|1|2|0115|2.3.1|
        40|Bed Status|IS|B|1|1|0116|2.3.1|2.3.1
        41|Account Status|IS|O|1|2|0117|2.3.1|
        42|Pending Location|PL|O|1|80||2.3.1|
        43|Prior Temporary Location|PL|O|1|80||2.3.1|
        44|Admit Date/Time|TS|O|1|26||2.3.1|
        45|Discharge Date/Time|TS|O|*|26||2.3.1|
        46|Current Patient Balance|NM|O|1|12||2.3.1|
        47|Total Charges|NM|O|1|12||2.3.1|
        48|Total Adjustments|NM|O|1|12||2.3.1|
        49|Total Payments|NM|O|1|12||2.3.1|
        50|Alternate Visit ID|CX|O|1|250|0203|2.3.1|
        51|Visit Indicator|IS|O|1|1|0326|2.3.1|
        52|Other Healthcare Provider|XCN|B|*|250|0010|2.3.1|2.4
        """,
        "PV2": """
        1|Prior Pending Location|PL|C|1|80||2.3.1|
        2|Accommodation Code|CE|O|1|250|0129|2.3.1|
        3|Admit Reason|CE|O|1|250||2.3.1|
        4|Transfer Reason|CE|O|1|250||2.3.1|
        5|Patient Valuables|ST|O|*|25||2.3.1|
        6|Patient Valuables Location|ST|O|1|25||2.3.1|
        7|Visit User Code|IS|O|*|2|0130|2.3.1|
        8|Expected Admit Date/Time|TS|O|1|26||2.3.1|
        9|Expected Discharge Date/Time|TS|O|1|26||2.3.1|
        10|Estimated Length of Inpatient Stay|NM|O|1|3||2.3.1|
        11|Actual Length of Inpatient Stay|NM|O|1|3||2.3.1|
        12|Visit Description|ST|O|1|50||2.3.1|
        13|Referral Source Code|XCN|O|*|250||2.3.1|
        14|Previous Service Date|DT|O|1|8||2.3.1|
        15|Employment Illness Related Indicator|ID|O|1|1|0136|2.3.1|
        16|Purge Status Code|IS|O|1|1|0213|2.3.1|
        17|Purge Status Date|DT|O|1|8||2.3.1|
        18|Special Program Code|IS|O|1|2|0214|2.3.1|
        19|Retention Indicator|ID|O|1|1|0136|2.3.1|
        20|Expected Number of Insurance Plans|NM|O|1|1||2.3.1|
        21|Visit Publicity Code|IS|O|1|1|0215|2.3.1|
        22|Visit Protection Indicator|ID|O|1|1|0136|2.3.1|2.6
        23|Clinic Organization Name|XON|O|*|250||2.3.1|
        24|Patient Status Code|IS|O|1|2|0216|2.3.1|
        25|Visit Priority Code|IS|O|1|1|0217|2.3.1|
        26|Previous Treatment Date|DT|O|1|8||2.3.1|
        27|Expected Discharge Disposition|IS|O|1|2|0112|2.3.1|
        28|Signature on File Date|DT|O|1|8||2.3.1|
        29|First Similar Illness Date|DT|O|1|8||2.3.1|
        30|Patient Charge Adjustment Code|CE|O|1|250|0218|2.3.1|
        31|Recurring Service Code|IS|O|1|2|0219|2.3.1|
        32|Billing Media Code|ID|O|1|1|0136|2.3.1|
        33|Expected Surgery Date and Time|TS|O|1|26||2.3.1|
        34|Military Partnership Code|ID|O|1|1|0136|2.3.1|
        35|Military Non-Availability Code|ID|O|1|1|0136|2.3.1|
        36|Newborn Baby Indicator|ID|O|1|1|0136|2.3.1|
        37|Baby Detained Indicator|ID|O|1|1|0136|2.3.1|
        38|Mode of Arrival Code|CE|O|1|250|0430|2.4|
        39|Recreational Drug Use Code|CE|O|*|250|0431|2.4|
        40|Admission Level of Care Code|CE|O|1|250|0432|2.4|
        41|Precaution Code|CE|O|*|250|0433|2.4|
        42|Patient Condition Code|CE|O|1|250|0434|2.4|
        43|Living Will Code|IS|O|1|2|0315|2.4|
        44|Organ Donor Code|IS|O|1|2|0316|2.4|
        45|Advance Directive Code|CE|O|*|250|0435|2.4|
        46|Patient Status Effective Date|DT|O|1|8||2.4|
        47|Expected LOA Return Date/Time|TS|C|1|26||2.4|
        48|Expected Pre-admission Testing Date/Time|TS|O|1|26||2.5|
        49|Notify Clergy Code|IS|O|*|20|0534|2.5|
        """,
        "AL1": """
        1|Set ID - AL1|SI|R|1|4||2.3.1|
        2|Allergen Type Code|CE|O|1|250|0127|2.3.1|
        3|Allergen Code/Mnemonic/Description|CE|R|1|250||2.3.1|
        4|Allergy Severity Code|CE|O|1|250|0128|2.3.1|
        5|Allergy Reaction Code|ST|O|*|15||2.3.1|
        6|Identification Date|DT|B|1|8||2.3.1|2.4
        """,
        "DG1": """
        1|Set ID - DG1|SI|R|1|4||2.3.1|
        2|Diagnosis Coding Method|ID|B|1|2|0053|2.3.1|2.3.1
        3|Diagnosis Code - DG1|CE|O|1|250|0051|2.3.1|
        4|Diagnosis Description|ST|B|1|40||2.3.1|2.3.1
        5|Diagnosis Date/Time|TS|O|1|26||2.3.1|
        6|Diagnosis Type|IS|R|1|2|0052|2.3.1|
        7|Major Diagnostic Category|CE|B|1|250|0118|2.3.1|2.3.1
        8|Diagnostic Related Group|CE|B|1|250|0055|2.3.1|2.3.1
        9|DRG Approval Indicator|ID|B|1|1|0136|2.3.1|2.3.1
        10|DRG Grouper Review Code|IS|B|1|2|0056|2.3.1|2.3.1
        11|Outlier Type|CE|B|1|250|0083|2.3.1|2.3.1
        12|Outlier Days|NM|B|1|3||2.3.1|2.3.1
        13|Outlier Cost|CP|B|1|12||2.3.1|2.3.1
        14|Grouper Version And Type|ST|B|1|4||2.3.1|2.3.1
        15|Diagnosis Priority|ID|O|1|2|0359|2.3.1|
        16|Diagnosing Clinician|XCN|O|*|250||2.3.1|
        17|Diagnosis Classification|IS|O|1|3|0228|2.3.1|
        18|Confidential Indicator|ID|O|1|1|0136|2.3.1|
        19|Attestation Date/Time|TS|O|1|26||2.3.1|
        20|Diagnosis Identifier|EI|C|1|427||2.5|
        21|Diagnosis Action Code|ID|C|1|1|0206|2.5|
        """,
        "OBR": """
        1|Set ID - OBR|SI|O|1|4||2.3.1|
        2|Placer Order Number|EI|C|1|22||2.3.1|
        3|Filler Order Number|EI|C|1|22||2.3.1|
        4|Universal Service Identifier|CE|R|1|250||2.3.1|
        5|Priority - OBR|ID|B|1|2||2.3.1|2.4
        6|Requested Date/Time|TS|B|1|26||2.3.1|2.4
        7|Observation Date/Time|TS|C|1|26||2.3.1|
        8|Observation End Date/Time|TS|O|1|26||2.3.1|
        9|Collection Volume|CQ|O|1|20||2.3.1|
        10|Collector Identifier|XCN|O|*|250||2.3.1|
        11|Specimen Action Code|ID|O|1|1|0065|2.3.1|
        12|Danger Code|CE|O|1|250||2.3.1|
        13|Relevant Clinical Information|ST|O|1|300||2.3.1|
        14|Specimen Received Date/Time|TS|B|1|26||2.3.1|2.5
        15|Specimen Source|SPS|B|1|300||2.3.1|2.5
        16|Ordering Provider|XCN|O|*|250||2.3.1|
        17|Order Callback Phone Number|XTN|O|2|250||2.3.1|
        18|Placer Field 1|ST|O|1|60||2.3.1|
        19|Placer Field 2|ST|O|1|60||2.3.1|
        20|Filler Field 1|ST|O|1|60||2.3.1|
        21|Filler Field 2|ST|O|1|60||2.3.1|
        22|Results Rpt/Status Chng - Date/Time|TS|C|1|26||2.3.1|
        23|Charge to Practice|MOC|O|1|40||2.3.1|
        24|Diagnostic Serv Sect ID|ID|O|1|10|0074|2.3.1|
        25|Result Status|ID|C|1|1|0123|2.3.1|
        26|Parent Result|PRL|O|1|400||2.3.1|
        27|Quantity/Timing|TQ|B|*|200||2.3.1|2.5
        28|Result Copies To|XCN|O|*|250||2.3.1|
        29|Parent|EIP|O|1|200||2.3.1|
        30|Transportation Mode|ID|O|1|20|0124|2.3.1|
        31|Reason for Study|CE|O|*|250||2.3.1|
        32|Principal Result Interpreter|NDL|O|1|200||2.3.1|2.6
        33|Assistant Result Interpreter|NDL|O|*|200||2.3.1|2.6
        34|Technician|NDL|O|*|200||2.3.1|2.6
        35|Transcriptionist|NDL|O|*|200||2.3.1|2.6
        36|Scheduled Date/Time|TS|O|1|26||2.3.1|
        37|Number of Sample Containers *|NM|O|1|4||2.3.1|
        38|Transport Logistics of Collected Sample|CE|O|*|250||2.3.1|
        39|Collector's Comment *|CE|O|*|250||2.3.1|
        40|Transport Arrangement Responsibility|CE|O|1|250||2.3.1|
        41|Transport Arranged|ID|O|1|30|0224|2.3.1|
        42|Escort Required|ID|O|1|1|0225|2.3.1|
        43|Planned Patient Transport Comment|CE|O|*|250||2.3.1|
        44|Procedure Code|CE|O|1|250|0088|2.3.1|
        45|Procedure Code Modifier|CE|O|*|250|0340|2.3.1|
        46|Placer Supplemental Service Information|CE|O|*|250|0411|2.4|
        47|Filler Supplemental Service Information|CE|O|*|250|0411|2.4|
        48|Medically Necessary Duplicate Procedure Reason.|CWE|C|1|250|0476|2.5|
        49|Result Handling|IS|O|1|2|0507|2.5|
        50|Parent Universal Service Identifier|CWE|O|1|250||2.5.1|
        """,
        "OBX": """
        1|Set ID - OBX|SI|O|1|4||2.3.1|
        2|Value Type|ID|C|1|2|0125|2.3.1|
        3|Observation Identifier|CE|R|1|250||2.3.1|
        4|Observation Sub-ID|ST|C|1|20||2.3.1|
        5|Observation Value|varies|C|*|99999||2.3.1|
        6|Units|CE|O|1|250||2.3.1|
        7|References Range|ST|O|1|60||2.3.1|
        8|Abnormal Flags|IS|O|*|5|0078|2.3.1|
        9|Probability|NM|O|1|5||2.3.1|
        10|Nature of Abnormal Test|ID|O|*|2|0080|2.3.1|
        11|Observation Result Status|ID|R|1|1|0085|2.3.1|
        12|Effective Date of Reference Range Values|TS|O|1|26||2.3.1|
        13|User Defined Access Checks|ST|O|1|20||2.3.1|
        14|Date/Time of the Observation|TS|O|1|26||2.3.1|
        15|Producer's Reference|CE|O|1|250||2.3.1|
        16|Responsible Observer|XCN|O|*|250||2.3.1|
        17|Observation Method|CE|O|*|250||2.3.1|
        18|Equipment Instance Identifier|EI|O|*|22||2.4|
        19|Date/Time of the Analysis|TS|O|1|26||2.4|
        20|Reserved for harmonization with V2.6|varies|O|1|||2.5.1|
        21|Reserved for harmonization with V2.6|varies|O|1|||2.5.1|
        22|Reserved for harmonization with V2.6|varies|O|1|||2.5.1|
        23|Performing Organization Name|XON|O|1|567||2.5.1|
        24|Performing Organization Address|XAD|O|1|631||2.5.1|
        25|Performing Organization Medical Director|XCN|O|1|3002||2.5.1|
        """,
        "ORC": """
        1|Order Control|ID|R|1|2|0119|2.3.1|
        2|Placer Order Number|EI|C|1|22||2.3.1|
        3|Filler Order Number|EI|C|1|22||2.3.1|
        4|Placer Group Number|EI|O|1|22||2.3.1|
        5|Order Status|ID|O|1|2|0038|2.3.1|
        6|Response Flag|ID|O|1|1|0121|2.3.1|
        7|Quantity/Timing|TQ|B|*|200||2.3.1|2.5
        8|Parent|EIP|O|1|200||2.3.1|
        9|Date/Time of Transaction|TS|O|1|26||2.3.1|
        10|Entered By|XCN|O|*|250||2.3.1|
        11|Verified By|XCN|O|*|250||2.3.1|
        12|Ordering Provider|XCN|O|*|250||2.3.1|
        13|Enterer's Location|PL|O|1|80||2.3.1|
        14|Call Back Phone Number|XTN|O|2|250||2.3.1|
        15|Order Effective Date/Time|TS|O|1|26||2.3.1|
        16|Order Control Code Reason|CE|O|1|250||2.3.1|
        17|Entering Organization|CE|O|1|250||2.3.1|
        18|Entering Device|CE|O|1|250||2.3.1|
        19|Action By|XCN|O|*|250||2.3.1|
        20|Advanced Beneficiary Notice Code|CE|O|1|250|0339|2.3.1|
        21|Ordering Facility Name|XON|O|*|250||2.3.1|
        22|Ordering Facility Address|XAD|O|*|250||2.3.1|
        23|Ordering Facility Phone Number|XTN|O|*|250||2.3.1|
        24|Ordering Provider Address|XAD|O|*|250||2.3.1|
        25|Order Status Modifier|CWE|O|1|250||2.4|
        26|Advanced Beneficiary Notice Override Reason|CWE|C|1|60|0552|2.5|
        27|Filler's Expected Availability Date/Time|TS|O|1|26||2.5|
        28|Confidentiality Code|CWE|O|1|250|0177|2.5|
        29|Order Type|CWE|O|1|250|0482|2.5|
        30|Enterer Authorization Mode|CNE|O|1|250|0483|2.5|
        31|Parent Universal Service Identifier|CWE|O|1|250||2.5.1|
        """,
        "NTE": """
        1|Set ID - NTE|SI|O|1|4||2.3.1|
        2|Source of Comment|ID|O|1|8|0105|2.3.1|
        3|Comment|FT|O|*|65536||2.3.1|
        4|Comment Type|CE|O|1|250|0364|2.3.1|
        """,
        "IN1": """
        1|Set ID - IN1|SI|R|1|4||2.3.1|
        2|Insurance Plan ID|CE|R|1|250|0072|2.3.1|
        3|Insurance Company ID|CX|R|*|250||2.3.1|
        4|Insurance Company Name|XON|O|*|250||2.3.1|
        5|Insurance Company Address|XAD|O|*|250||2.3.1|
        6|Insurance Co Contact Person|XPN|O|*|250||2.3.1|
        7|Insurance Co Phone Number|XTN|O|*|250||2.3.1|
        8|Group Number|ST|O|1|12||2.3.1|
        9|Group Name|XON|O|*|250||2.3.1|
        10|Insured's Group Emp ID|CX|O|*|250||2.3.1|
        11|Insured's Group Emp Name|XON|O|*|250||2.3.1|
        12|Plan Effective Date|DT|O|1|8||2.3.1|
        13|Plan Expiration Date|DT|O|1|8||2.3.1|
        14|Authorization Information|AUI|O|1|239||2.3.1|
        15|Plan Type|IS|O|1|3|0086|2.3.1|
        16|Name Of Insured|XPN|O|*|250||2.3.1|
        17|Insured's Relationship To Patient|CE|O|1|250|0063|2.3.1|
        18|Insured's Date Of Birth|TS|O|1|26||2.3.1|
        19|Insured's Address|XAD|O|*|250||2.3.1|
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
        30|Verification By|XCN|O|*|250||2.3.1|
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
        42|Insured's Employment Status|CE|O|1|250|0066|2.3.1|
        43|Insured's Administrative Sex|IS|O|1|1|0001|2.3.1|
        44|Insured's Employer's Address|XAD|O|*|250||2.3.1|
        45|Verification Status|ST|O|1|2||2.3.1|
        46|Prior Insurance Plan ID|IS|O|1|8|0072|2.3.1|
        47|Coverage Type|IS|O|1|3|0309|2.3.1|
        48|Handicap|IS|O|1|2|0295|2.3.1|
        49|Insured's ID Number|CX|O|*|250||2.3.1|
        50|Signature Code|IS|O|1|1|0535|2.5|
        51|Signature Code Date|DT|O|1|8||2.5|
        52|Insured's Birth Place|ST|O|1|250||2.5|
        53|VIP Indicator|IS|O|1|2|0099|2.5|
        """,
        "GT1": """
        1|Set ID - GT1|SI|R|1|4||2.3.1|
        2|Guarantor Number|CX|O|*|250||2.3.1|
        3|Guarantor Name|XPN|R|*|250||2.3.1|
        4|Guarantor Spouse Name|XPN|O|*|250||2.3.1|
        5|Guarantor Address|XAD|O|*|250||2.3.1|
        6|Guarantor Ph Num - Home|XTN|O|*|250||2.3.1|
        7|Guarantor Ph Num - Business|XTN|O|*|250||2.3.1|
        8|Guarantor Date/Time Of Birth|TS|O|1|26||2.3.1|
        9|Guarantor Administrative Sex|IS|O|1|1|0001|2.3.1|
        10|Guarantor Type|IS|O|1|2|0068|2.3.1|
        11|Guarantor Relationship|CE|O|1|250|0063|2.3.1|
        12|Guarantor SSN|ST|O|1|11||2.3.1|
        13|Guarantor Date - Begin|DT|O|1|8||2.3.1|
        14|Guarantor Date - End|DT|O|1|8||2.3.1|
        15|Guarantor Priority|NM|O|1|2||2.3.1|
        16|Guarantor Employer Name|XPN|O|*|250||2.3.1|
        17|Guarantor Employer Address|XAD|O|*|250||2.3.1|
        18|Guarantor Employer Phone Number|XTN|O|*|250||2.3.1|
        19|Guarantor Employee ID Number|CX|O|*|250||2.3.1|
        20|Guarantor Employment Status|IS|O|1|2|0066|2.3.1|
        21|Guarantor Organization Name|XON|O|*|250||2.3.1|
        22|Guarantor Billing Hold Flag|ID|O|1|1|0136|2.3.1|
        23|Guarantor Credit Rating Code|CE|O|1|250|0341|2.3.1|
        24|Guarantor Death Date And Time|TS|O|1|26||2.3.1|
        25|Guarantor Death Flag|ID|O|1|1|0136|2.3.1|
        26|Guarantor Charge Adjustment Code|CE|O|1|250|0218|2.3.1|
        27|Guarantor Household Annual Income|CP|O|1|10||2.3.1|
        28|Guarantor Household Size|NM|O|1|3||2.3.1|
        29|Guarantor Employer ID Number|CX|O|*|250||2.3.1|
        30|Guarantor Marital Status Code|CE|O|1|250|0002|2.3.1|
        31|Guarantor Hire Effective Date|DT|O|1|8||2.3.1|
        32|Employment Stop Date|DT|O|1|8||2.3.1|
        33|Living Dependency|IS|O|1|2|0223|2.3.1|
        34|Ambulatory Status|IS|O|*|2|0009|2.3.1|
        35|Citizenship|CE|O|*|250|0171|2.3.1|
        36|Primary Language|CE|O|1|250|0296|2.3.1|
        37|Living Arrangement|IS|O|1|2|0220|2.3.1|
        38|Publicity Code|CE|O|1|250|0215|2.3.1|
        39|Protection Indicator|ID|O|1|1|0136|2.3.1|
        40|Student Indicator|IS|O|1|2|0231|2.3.1|
        41|Religion|CE|O|1|250|0006|2.3.1|
        42|Mother's Maiden Name|XPN|O|*|250||2.3.1|
        43|Nationality|CE|O|1|250|0212|2.3.1|
        44|Ethnic Group|CE|O|*|250|0189|2.3.1|
        45|Contact Person's Name|XPN|O|*|250||2.3.1|
        46|Contact Person's Telephone Number|XTN|O|*|250||2.3.1|
        47|Contact Reason|CE|O|1|250|0222|2.3.1|
        48|Contact Relationship|IS|O|1|3|0063|2.3.1|
        49|Job Title|ST|O|1|20||2.3.1|
        50|Job Code/Class|JCC|O|1|20||2.3.1|
        51|Guarantor Employer's Organization Name|XON|O|*|250||2.3.1|
        52|Handicap|IS|O|1|2|0295|2.3.1|
        53|Job Status|IS|O|1|2|0311|2.3.1|
        54|Guarantor Financial Class|FC|O|1|50||2.3.1|
        55|Guarantor Race|CE|O|*|250|0005|2.3.1|
        56|Guarantor Birth Place|ST|O|1|250||2.5|
        57|VIP Indicator|IS|O|1|2|0099|2.5|
        """,
        "MSA": """
        1|Acknowledgment Code|ID|R|1|2|0008|2.3.1|
        2|Message Control ID|ST|R|1|20||2.3.1|
        3|Text Message|ST|B|1|80||2.3.1|2.5
        4|Expected Sequence Number|NM|O|1|15||2.3.1|
        5|Delayed Acknowledgment Type|withdrawn|X|1|||2.3.1|2.3.1
        6|Error Condition|CE|B|1|250|0357|2.3.1|2.5
        """,
        "ERR": """
        1|Error Code and Location|ELD|B|*|493||2.3.1|2.5
        2|Error Location|ERL|O|*|18||2.5|
        3|HL7 Error Code|CWE|R|1|705|0357|2.5|
        4|Severity|ID|R|1|2|0516|2.5|
        5|Application Error Code|CWE|O|1|705|0533|2.5|
        6|Application Error Parameter|ST|O|10|80||2.5|
        7|Diagnostic Information|TX|O|1|2048||2.5|
        8|User Message|TX|O|1|250||2.5|
        9|Inform Person Indicator|IS|O|*|20|0517|2.5|
        10|Override Type|CWE|O|1|705|0518|2.5|
        11|Override Reason Code|CWE|O|*|705|0519|2.5|
        12|Help Desk Contact Point|XTN|O|*|652||2.5|
        """,
        "QRD": """
        1|Query Date/Time|TS|R|1|26||2.3.1|
        2|Query Format Code|ID|R|1|1|0106|2.3.1|
        3|Query Priority|ID|R|1|1|0091|2.3.1|
        4|Query ID|ST|R|1|10||2.3.1|
        5|Deferred Response Type|ID|O|1|1|0107|2.3.1|
        6|Deferred Response Date/Time|TS|O|1|26||2.3.1|
        7|Quantity Limited Request|CQ|R|1|10|0126|2.3.1|
        8|Who Subject Filter|XCN|R|*|250||2.3.1|
        9|What Subject Filter|CE|R|*|250|0048|2.3.1|
        10|What Department Data Code|CE|R|*|250||2.3.1|
        11|What Data Code Value Qual.|VR|O|*|20||2.3.1|
        12|Query Results Level|ID|O|1|1|0108|2.3.1|
        """,
        "QRF": """
        1|Where Subject Filter|ST|R|*|20||2.3.1|
        2|When Data Start Date/Time|TS|B|1|26||2.3.1|2.4
        3|When Data End Date/Time|TS|B|1|26||2.3.1|2.4
        4|What User Qualifier|ST|O|*|60||2.3.1|
        5|Other QRY Subject Filter|ST|O|*|60||2.3.1|
        6|Which Date/Time Qualifier|ID|O|*|12|0156|2.3.1|
        7|Which Date/Time Status Qualifier|ID|O|*|12|0157|2.3.1|
        8|Date/Time Selection Qualifier|ID|O|*|12|0158|2.3.1|
        9|When Quantity/Timing Qualifier|TQ|O|1|60||2.3.1|2.6
        10|Search Confidence Threshold|NM|O|1|10||2.4|
        """,
        "QPD": """
        1|Message Query Name|CE|R|1|250|0471|2.4|
        2|Query Tag|ST|C|1|32||2.4|
        3|User Parameters (in successive fields)|varies|O|1|256||2.4|
        """,
        "RCP": """
        1|Query Priority|ID|O|1|1|0091|2.4|
        2|Quantity Limited Request|CQ|O|1|10|0126|2.4|
        3|Response Modality|CE|O|1|250|0394|2.4|
        4|Execution and Delivery Time|TS|C|1|26||2.4|
        5|Modify Indicator|ID|O|1|1|0395|2.4|
        6|Sort-by Field|SRT|O|*|512||2.4|
        7|Segment group inclusion|ID|O|*|256||2.4|
        """,
        "QAK": """
        1|Query Tag|ST|C|1|32||2.3.1|
        2|Query Response Status|ID|O|1|2|0208|2.3.1|
        3|Message Query Name|CE|O|1|250|0471|2.4|
        4|Hit Count|NM|O|1|10||2.4|
        5|This payload|NM|O|1|10||2.4|
        6|Hits remaining|NM|O|1|10||2.4|
        """,
        "DSC": """
        1|Continuation Pointer|ST|O|1|180||2.3.1|
        2|Continuation Style|ID|O|1|1|0398|2.4|
        """,
    ]
    static let types2_5_1: [String: String] = [
        "AUI": """
        Authorization Number|ST|O|
        Date|DT|O|
        Source|ST|O|
        """,
        "CE": """
        Identifier|ST|O|
        Text|ST|O|
        Name of Coding System|ID|O|
        Alternate Identifier|ST|O|
        Alternate Text|ST|O|
        Name of Alternate Coding System|ID|O|
        """,
        "CNE": """
        Identifier|ST|R|
        Text|ST|O|
        Name of Coding System|ID|O|
        Alternate Identifier|ST|O|
        Alternate Text|ST|O|
        Name of Alternate Coding System|ID|O|
        Coding System Version ID|ST|C|
        Alternate Coding System Version ID|ST|O|
        Original Text|ST|O|
        """,
        "CP": """
        Price|MO|R|
        Price Type|ID|O|
        From Value|NM|O|
        To Value|NM|O|
        Range Units|CE|O|
        Range Type|ID|O|
        """,
        "CQ": """
        Quantity|NM|O|
        Units|CE|O|
        """,
        "CWE": """
        Identifier|ST|O|
        Text|ST|O|
        Name of Coding System|ID|O|
        Alternate Identifier|ST|O|
        Alternate Text|ST|O|
        Name of Alternate Coding System|ID|O|
        Coding System Version ID|ST|C|
        Alternate Coding System Version ID|ST|O|
        Original Text|ST|O|
        """,
        "CX": """
        ID Number|ST|R|
        Check Digit|ST|O|
        Check Digit Scheme|ID|O|
        Assigning Authority|HD|O|
        Identifier Type Code|ID|O|
        Assigning Facility|HD|O|
        Effective Date|DT|O|
        Expiration Date|DT|O|
        Assigning Jurisdiction|CWE|O|
        Assigning Agency or Department|CWE|O|
        """,
        "DLD": """
        Discharge Location|IS|R|
        Effective Date|TS|O|
        """,
        "DLN": """
        License Number|ST|R|
        Issuing State, Province, Country|IS|O|
        Expiration Date|DT|O|
        """,
        "DR": """
        Range Start Date/Time|TS|O|
        Range End Date/Time|TS|O|
        """,
        "DT": "",
        "DTM": "",
        "ED": """
        Source Application|HD|O|
        Type of Data|ID|R|
        Data Subtype|ID|O|
        Encoding|ID|R|
        Data|TX|R|
        """,
        "EI": """
        Entity Identifier|ST|O|
        Namespace ID|IS|O|
        Universal ID|ST|C|
        Universal ID Type|ID|C|
        """,
        "EIP": """
        Placer Assigned Identifier|EI|O|
        Filler Assigned Identifier|EI|O|
        """,
        "ELD": """
        Segment ID|ST|O|
        Segment Sequence|NM|O|
        Field Position|NM|O|
        Code Identifying Error|CE|O|
        """,
        "ERL": """
        Segment ID|ST|R|
        Segment Sequence|NM|R|
        Field Position|NM|O|
        Field Repetition|NM|O|
        Component Number|NM|O|
        Sub-Component Number|NM|O|
        """,
        "FC": """
        Financial Class Code|IS|R|
        Effective Date|TS|O|
        """,
        "FN": """
        Surname|ST|R|
        Own Surname Prefix|ST|O|
        Own Surname|ST|O|
        Surname Prefix From Partner/Spouse|ST|O|
        Surname From Partner/Spouse|ST|O|
        """,
        "FT": "",
        "HD": """
        Namespace ID|IS|O|
        Universal ID|ST|C|
        Universal ID Type|ID|C|
        """,
        "ID": "",
        "IS": "",
        "JCC": """
        Job Code|IS|O|
        Job Class|IS|O|
        Job Description Text|TX|O|
        """,
        "MO": """
        Quantity|NM|O|
        Denomination|ID|O|
        """,
        "MOC": """
        Monetary Amount|MO|O|
        Charge Code|CE|O|
        """,
        "MSG": """
        Message Code|ID|R|
        Trigger Event|ID|R|
        Message Structure|ID|R|
        """,
        "NDL": """
        Name|CNN|O|
        Start Date/time|TS|O|
        End Date/time|TS|O|
        Point of Care|IS|O|
        Room|IS|O|
        Bed|IS|O|
        Facility|HD|O|
        Location Status|IS|O|
        Patient Location Type|IS|O|
        Building|IS|O|
        Floor|IS|O|
        """,
        "NM": "",
        "PL": """
        Point of Care|IS|O|
        Room|IS|O|
        Bed|IS|O|
        Facility|HD|O|
        Location Status|IS|O|
        Person Location Type|IS|C|
        Building|IS|O|
        Floor|IS|O|
        Location Description|ST|O|
        Comprehensive Location Identifier|EI|O|
        Assigning Authority for Location|HD|O|
        """,
        "PRL": """
        Parent Observation Identifier|CE|R|
        Parent Observation Sub-identifier|ST|O|
        Parent Observation Value Descriptor|TX|O|
        """,
        "PT": """
        Processing ID|ID|O|
        Processing Mode|ID|O|
        """,
        "QIP": """
        Segment Field Name|ST|R|
        Values|ST|R|
        """,
        "QSC": """
        Segment Field Name|ST|R|
        Relational Operator|ID|O|
        Value|ST|O|
        Relational Conjunction|ID|O|
        """,
        "RI": """
        Repeat Pattern|IS|O|
        Explicit Time Interval|ST|O|
        """,
        "RP": """
        Pointer|ST|O|
        Application ID|HD|O|
        Type of Data|ID|O|
        Subtype|ID|O|
        """,
        "SAD": """
        Street or Mailing Address|ST|O|
        Street Name|ST|O|
        Dwelling Number|ST|O|
        """,
        "SCV": """
        Parameter Class|CWE|O|
        Parameter Value|ST|O|
        """,
        "SI": "",
        "SN": """
        Comparator|ST|O|
        Num1|NM|O|
        Separator/Suffix|ST|O|
        Num2|NM|O|
        """,
        "SPS": """
        Specimen Source Name or Code|CWE|O|
        Additives|CWE|O|
        Specimen Collection Method|TX|O|
        Body Site|CWE|O|
        Site Modifier|CWE|O|
        Collection Method Modifier Code|CWE|O|
        Specimen Role|CWE|O|
        """,
        "SRT": """
        Sort-by Field|ST|R|
        Sequencing|ID|O|
        """,
        "ST": "",
        "TM": "",
        "TQ": """
        Quantity|CQ|O|
        Interval|RI|O|
        Duration|ST|O|
        Start Date/Time|TS|O|
        End Date/Time|TS|O|
        Priority|ST|O|
        Condition|ST|O|
        Text|TX|O|
        Conjunction|ID|O|
        Order Sequencing|OSD|O|
        Occurrence Duration|CE|O|
        Total Occurrences|NM|O|
        """,
        "TS": """
        Time|DTM|R|
        Degree of Precision|ID|B|
        """,
        "TX": "",
        "VID": """
        Version ID|ID|O|
        Internationalization Code|CE|O|
        International Version ID|CE|O|
        """,
        "VR": """
        First Data Code Value|ST|O|
        Last Data Code Value|ST|O|
        """,
        "XAD": """
        Street Address|SAD|O|
        Other Designation|ST|O|
        City|ST|O|
        State or Province|ST|O|
        Zip or Postal Code|ST|O|
        Country|ID|O|
        Address Type|ID|O|
        Other Geographic Designation|ST|O|
        County/Parish Code|IS|O|
        Census Tract|IS|O|
        Address Representation Code|ID|O|
        Address Validity Range|DR|B|
        Effective Date|TS|O|
        Expiration Date|TS|O|
        """,
        "XCN": """
        ID Number|ST|O|
        Family Name|FN|O|
        Given Name|ST|O|
        Second and Further Given Names or Initials Thereof|ST|O|
        Suffix (e.g., JR or III)|ST|O|
        Prefix (e.g., DR)|ST|O|
        Degree (e.g., MD)|IS|B|
        Source Table|IS|C|
        Assigning Authority|HD|O|
        Name Type Code|ID|O|
        Identifier Check Digit|ST|O|
        Check Digit Scheme|ID|C|
        Identifier Type Code|ID|O|
        Assigning Facility|HD|O|
        Name Representation Code|ID|O|
        Name Context|CE|O|
        Name Validity Range|DR|B|
        Name Assembly Order|ID|O|
        Effective Date|TS|O|
        Expiration Date|TS|O|
        Professional Suffix|ST|O|
        Assigning Jurisdiction|CWE|O|
        Assigning Agency or Department|CWE|O|
        """,
        "XON": """
        Organization Name|ST|O|
        Organization Name Type Code|IS|O|
        ID Number|NM|B|
        Check Digit|NM|O|
        Check Digit Scheme|ID|O|
        Assigning Authority|HD|O|
        Identifier Type Code|ID|O|
        Assigning Facility|HD|O|
        Name Representation Code|ID|O|
        Organization Identifier|ST|O|
        """,
        "XPN": """
        Family Name|FN|O|
        Given Name|ST|O|
        Second and Further Given Names or Initials Thereof|ST|O|
        Suffix (e.g., JR or III)|ST|O|
        Prefix (e.g., DR)|ST|O|
        Degree (e.g., MD)|IS|B|
        Name Type Code|ID|O|
        Name Representation Code|ID|O|
        Name Context|CE|O|
        Name Validity Range|DR|B|
        Name Assembly Order|ID|O|
        Effective Date|TS|O|
        Expiration Date|TS|O|
        Professional Suffix|ST|O|
        """,
        "XTN": """
        Telephone Number|ST|B|
        Telecommunication Use Code|ID|O|
        Telecommunication Equipment Type|ID|O|
        Email Address|ST|O|
        Country Code|NM|O|
        Area/City Code|NM|O|
        Local Number|NM|O|
        Extension|NM|O|
        Any Text|ST|O|
        Extension Prefix|ST|O|
        Speed Dial Code|ST|O|
        Unformatted Telephone number|ST|C|
        """,
        "CNN": """
        ID Number|ST|O|
        Family Name|ST|O|
        Given Name|ST|O|
        Second and Further Given Names or Initials Thereof|ST|O|
        Suffix (e.g., JR or III)|ST|O|
        Prefix (e.g., DR)|ST|O|
        Degree (e.g., MD|IS|O|
        Source Table|IS|C|
        Assigning Authority - Namespace ID|IS|C|
        Assigning Authority - Universal ID|ST|C|
        Assigning Authority - Universal ID Type|ID|C|
        """,
        "OSD": """
        Sequence/Results Flag|ID|R|
        Placer Order Number: Entity Identifier|ST|R|
        Placer Order Number: Namespace ID|IS|O|
        Filler Order Number: Entity Identifier|ST|R|
        Filler Order Number: Namespace ID|IS|O|
        Sequence Condition Value|ST|O|
        Maximum Number of Repeats|NM|O|
        Placer Order Number: Universal ID|ST|R|
        Placer Order Number: Universal ID Type|ID|O|
        Filler Order Number: Universal ID|ST|R|
        Filler Order Number: Universal ID Type|ID|O|
        """,
    ]
    static let sets2_5_1: [String: Set<String>] = [
        "0001": ["F", "M", "O", "U", "A", "N"],
        "0004": ["E", "I", "O", "P", "R", "B", "C", "N", "U"],
        "0003": ["A01", "A02", "A03", "A04", "A05", "A06", "A07", "A08", "A09", "A10", "A11", "A12", "A13", "A14", "A15", "A16", "A17", "A18", "A19", "A20", "A21", "A22", "A23", "A24", "A25", "A26", "A27", "A28", "A29", "A30", "A31", "A32", "A33", "A34", "A35", "A36", "A37", "A38", "A39", "A40", "A41", "A42", "A43", "A44", "A45", "A46", "A47", "A48", "A49", "A50", "A51", "A52", "A53", "A54", "A55", "A60", "A61", "A62", "B01", "B02", "B03", "B04", "B05", "B06", "B07", "B08", "C01", "C02", "C03", "C04", "C05", "C06", "C07", "C08", "C09", "C10", "C11", "C12", "CNQ", "I01", "I02", "I03", "I04", "I05", "I06", "I07", "I08", "I09", "I10", "I11", "I12", "I13", "I14", "I15", "J01", "J02", "K11", "K13", "K15", "K21", "K22", "K23", "K24", "K25", "K31", "M01", "M02", "M03", "M04", "M05", "M06", "M07", "M08", "M09", "M10", "M11", "M12", "M13", "M14", "M15", "N01", "N02", "O01", "O02", "O03", "O04", "O05", "O06", "O07", "O08", "O09", "O10", "O11", "O12", "O13", "O14", "O15", "O16", "O17", "O18", "O19", "O20", "O21", "O22", "O23", "O24", "O25", "O26", "O27", "O28", "O29", "O30", "O31", "O32", "O33", "O34", "O35", "O36", "P01", "P02", "P03", "P04", "P05", "P06", "P07", "P08", "P09", "P10", "P11", "P12", "PC1", "PC2", "PC3", "PC4", "PC5", "PC6", "PC7", "PC8", "PC9", "PCA", "PCB", "PCC", "PCD", "PCE", "PCF", "PCG", "PCH", "PCJ", "PCK", "PCL", "Q01", "Q02", "Q03", "Q04", "Q05", "Q06", "Q07", "Q08", "Q09", "Q11", "Q13", "Q15", "Q16", "Q17", "Q21", "Q22", "Q23", "Q24", "Q25", "Q26", "Q27", "Q28", "Q29", "Q30", "R01", "Q31", "R02", "R03", "R04", "ROR", "R07", "R08", "R09", "R21", "R22", "R23", "R24", "R30", "R31", "R32", "S01", "S02", "S03", "S04", "S05", "S06", "S07", "S08", "S09", "S10", "S11", "S12", "S13", "S14", "S15", "S16", "S17", "S18", "S19", "S20", "S21", "S22", "S23", "S24", "S25", "S26", "T01", "T02", "T03", "T04", "T05", "T06", "T07", "T08", "T09", "T10", "T11", "T12", "U01", "U02", "U03", "U04", "U05", "U06", "U07", "U08", "U09", "U10", "U11", "U12", "U13", "V01", "V02", "V03", "V04", "Varies", "W01", "W02"],
        "0008": ["AA", "AE", "AR", "CA", "CE", "CR"],
        "0076": ["ACK", "ADR", "ADT", "BAR", "CRM", "BPS", "BRP", "BRT", "BTS", "CSU", "DFT", "DOC", "DSR", "EAC", "EAN", "EAR", "EDR", "EQQ", "ERP", "ESR", "ESU", "INR", "INU", "LSR", "LSU", "MCF", "MDM", "MFD", "MFK", "MFN", "MFQ", "MFR", "NMD", "NMQ", "NMR", "OMB", "OMD", "OMG", "OMI", "OML", "OMN", "OMP", "OMS", "ORB", "ORD", "ORF", "ORG", "ORI", "ORL", "ORM", "ORN", "ORP", "ORR", "ORS", "ORU", "OSQ", "OSR", "OUL", "PEX", "PGL", "PIN", "PMU", "PPG", "PPP", "PPR", "PPT", "PPV", "PRR", "PTR", "QBP", "QCK", "QCN", "QRY", "QSB", "QSX", "QVR", "RAR", "RAS", "RCI", "RCL", "RDE", "RDR", "RDS", "RDY", "REF", "RER", "RGR", "RGV", "ROR", "RPA", "RPI", "RPL", "RPR", "RQA", "RQC", "RQI", "RQP", "RQQ", "RRA", "RRD", "RRE", "RRG", "RRI", "RSP", "RTB", "SIU", "SPQ", "SQM", "SQR", "SRM", "SRR", "SSR", "SSU", "SUR", "TBR", "TCR", "TCU", "UDM", "VQQ", "VXQ", "VXR", "VXU", "VXX"],
        "0103": ["D", "P", "T"],
        "0207": ["A", "R", "I", "T", "Not present"],
        "0085": ["C", "D", "F", "I", "N", "O", "P", "R", "S", "X", "U", "W"],
        "0078": ["L", "H", "LL", "HH", "<", ">", "N", "A", "AA", "null", "U", "D", "B", "W", "S", "R", "I", "MS", "VS"],
        "0119": ["NW", "OK", "UA", "PR", "CA", "OC", "CR", "UC", "DC", "OD", "DR", "UD", "HD", "OH", "UH", "HR", "RL", "OE", "OR", "UR", "RP", "RU", "RO", "RQ", "UM", "PA", "CH", "XO", "XX", "UX", "XR", "DE", "RE", "RR", "SR", "SS", "SC", "SN", "NA", "CN", "RF", "AF", "DF", "FU", "OF", "UF", "LI", "UN", "OP", "PY"],
        "0516": ["W", "I", "E"],
        "0357": ["0", "100", "101", "102", "103", "200", "201", "202", "203", "204", "205", "206", "207"],
        "0125": ["AD", "CE", "CF", "CK", "CN", "CP", "CX", "DT", "ED", "FT", "MO", "NM", "PN", "RP", "SN", "ST", "TM", "TN", "TS", "TX", "XAD", "XCN", "XON", "XPN", "XTN"],
        "0155": ["AL", "NE", "ER", "SU"],
        "0206": ["A", "D", "U"],
        "0396": ["99zzz or L", "ACR", "ART", "ANS+", "AS4", "AS4E", "ATC", "C4", "C5", "CAS", "CD2", "CDCA", "CDCM", "CDS", "CE", "CLP", "CPTM", "CST", "CVX", "DCM", "E", "E5", "E6", "E7", "ENZC", "FDDC", "FDDX", "FDK", "HB", "HCPCS", "HCPT", "HHC", "HI", "HL7nnnn", "HOT", "HPC", "I10", "I10P", "I9", "I9C", "IBT", "IBTnnnn", "IC2", "ICD10AM", "ICD10CA", "ICDO", "ICS", "ICSD", "ISOnnnn", "ISO+", "IUPP", "IUPC", "JC8", "JC10", "JJ1017", "LB", "LN", "MCD", "MCR", "MDDX", "MEDC", "MEDR", "MEDX", "MGPI", "MVX", "NDA", "NDC", "NIC", "NPI", "NUBC", "OHA", "POS", "RC", "SDM", "SNM", "SNM3", "SNT", "UC", "UMD", "UML", "UPC", "UPIN", "USPS", "W1", "W2", "W4", "WC"],
    ]
}
