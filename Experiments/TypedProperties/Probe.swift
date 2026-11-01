import CoreData
import Darwin
import Foundation
import GraphEvo
import GraphEvoModel

// These two synthetic entities deliberately do not manipulate Graph's Managed* classes.
// The experiment isolates property representation; it is not an alternate Graph opener.
enum Failure: Error { case invalidRequest, assertion(String) }
func require(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
    guard try condition() else { throw Failure.assertion(message) }
}
enum Variant: String { case envelope, typed, indexed }
let slots = ["integerValue", "booleanValue", "doubleValue", "dateValue", "textValue", "bytesValue"]

func model(_ variant: Variant) -> NSManagedObjectModel {
    func attr(_ name: String, _ type: NSAttributeType, optional: Bool = true) -> NSAttributeDescription {
        let a=NSAttributeDescription();a.name=name;a.attributeType=type;a.isOptional=optional;return a
    }
    let n=NSEntityDescription();n.name="ProbeNode";n.managedObjectClassName="NSManagedObject"
    let p=NSEntityDescription();p.name="ProbeProperty";p.managedObjectClassName="NSManagedObject"
    let ps=NSRelationshipDescription();ps.name="properties";ps.destinationEntity=p;ps.maxCount=0;ps.minCount=0;ps.isOptional=true;ps.deleteRule = .cascadeDeleteRule
    let owner=NSRelationshipDescription();owner.name="node";owner.destinationEntity=n;owner.maxCount=1;owner.isOptional=false;owner.deleteRule = .nullifyDeleteRule
    ps.inverseRelationship=owner;owner.inverseRelationship=ps
    n.properties=[attr("id",.integer64AttributeType,optional:false),attr("kind",.integer16AttributeType,optional:false),ps]
    var attributes=[attr("name",.stringAttributeType,optional:false)]
    if variant == .envelope {
        let value=attr("object",.transformableAttributeType);value.valueTransformerName="GraphValueTransformer"
        value.attributeValueClassName="NSObject";value.allowsExternalBinaryDataStorage=true;attributes.append(value)
    } else {
        attributes += [attr("tag",.integer16AttributeType,optional:false),attr("integerValue",.integer64AttributeType),attr("booleanValue",.booleanAttributeType),
                       attr("doubleValue",.doubleAttributeType),attr("dateValue",.dateAttributeType),attr("textValue",.stringAttributeType),attr("bytesValue",.binaryDataAttributeType)]
        attributes.last!.allowsExternalBinaryDataStorage=true
    }
    p.properties=attributes+[owner]
    func index(_ entity: NSEntityDescription,_ names:[String]) -> NSFetchIndexDescription {
        NSFetchIndexDescription(name:entity.name!+"_"+names.joined(separator:"_"),elements:names.map {NSFetchIndexElementDescription(property:entity.propertiesByName[$0]!,collationType:.binary)})
    }
    n.indexes=[index(n,["id"])];var propertyIndexes=[index(p,["name","node"])]
    if variant == .indexed {
        propertyIndexes += ["integerValue","booleanValue","doubleValue","dateValue","textValue"].map {index(p,["name","tag",$0])}
    }
    p.indexes=propertyIndexes
    let d=NSEntityDescription();d.name="ProbeDecimal";d.managedObjectClassName="NSManagedObject";d.properties=[attr("value",.decimalAttributeType)]
    let m=NSManagedObjectModel();m.entities=[n,p,d];m.versionIdentifiers=["TypedPropertyLab.1."+variant.rawValue];return m
}

// A single authoritative value: scalar columns OR opaque bytes, never a duplicate envelope.
func put(_ value: GraphValue, into row:NSManagedObject, variant:Variant) throws {
    if variant == .envelope {row.setValue(try GraphValueCodec.encode(value),forKey:"object");return}
    for key in slots {row.setValue(nil,forKey:key)}
    var tag:Int16=0;var key:String?;var native:Any?
    switch value {
    case .null: break
    case .boolean(let v):tag=1;key="booleanValue";native=v
    case .integer(let v):tag=2;key="integerValue";native=v
    case .unsignedInteger(let v):tag=3;key="textValue";native=String(repeating:"0",count:20-String(v).count)+String(v)
    case .floatingPoint(let v):try require(v.isFinite,"Non-finite double");tag=4;key="doubleValue";native=v
    case .decimal(let v):tag=5;key="textValue";native=NSDecimalNumber(decimal:v).stringValue
    case .string(let v):
        if v.utf8.contains(0) {tag=12;key="bytesValue";native=try GraphValueCodec.encode(value)}
        else {tag=6;key="textValue";native=v}
    case .data(let v):tag=7;key="bytesValue";native=v
    case .date(let v):try require(v.timeIntervalSinceReferenceDate.isFinite,"Non-finite date");tag=8;key="dateValue";native=v
    case .url(let v):
        try require(v.baseURL == nil,"Relative URLs with a base need a separate lossless codec")
        tag=9;key="textValue";native=v.absoluteString
    case .uuid(let v):tag=10;key="textValue";native=v.uuidString
    case .array,.object,.encoded:tag=11;key="bytesValue";native=try GraphValueCodec.encode(value)
    }
    row.setValue(tag,forKey:"tag");if let key {row.setValue(native,forKey:key)}
}
func get(_ row:NSManagedObject,variant:Variant) throws -> GraphValue {
    if variant == .envelope {guard let data=row.value(forKey:"object") as? Data else {throw Failure.assertion("Missing envelope")};return try GraphValueCodec.decode(data)}
    let tag=(row.value(forKey:"tag") as! NSNumber).intValue
    let field:[Int:String]=[1:"booleanValue",2:"integerValue",3:"textValue",4:"doubleValue",5:"textValue",6:"textValue",7:"bytesValue",8:"dateValue",9:"textValue",10:"textValue",11:"bytesValue",12:"bytesValue"]
    try require((0...12).contains(tag),"Unknown tag")
    let key=field[tag]
    for slot in slots {try require((row.value(forKey:slot) != nil) == (slot==key),"Invalid value-column shape")}
    if tag==0{return .null}
    let v=row.value(forKey:key!)!
    switch tag {
    case 1:return .boolean((v as! NSNumber).boolValue)
    case 2:return .integer((v as! NSNumber).int64Value)
    case 3:guard let number=UInt64(v as! String) else {throw Failure.assertion("Invalid uint")};return .unsignedInteger(number)
    case 4:return .floatingPoint((v as! NSNumber).doubleValue)
    case 5:guard let d=Decimal(string:v as! String,locale:Locale(identifier:"en_US_POSIX")) else {throw Failure.assertion("Invalid decimal")};return .decimal(d)
    case 6:return .string(v as! String)
    case 7:return .data(v as! Data)
    case 8:return .date(v as! Date)
    case 9:guard let u=URL(string:v as! String) else {throw Failure.assertion("Invalid URL")};return .url(u)
    case 10:guard let u=UUID(uuidString:v as! String) else {throw Failure.assertion("Invalid UUID")};return .uuid(u)
    default:return try GraphValueCodec.decode(v as! Data)
    }
}
func values(_ i:Int)->[String:GraphValue] {
    var result:[String:GraphValue]=["score":.integer(Int64(i%1000)),"name":.string(String(format:"name%06d",i)),"active":.boolean(i%2==0),
        "ratio":.floatingPoint(Double(i%1000)/10),"when":.date(Date(timeIntervalSince1970:Double(i))),
        "amount":.decimal(Decimal(i)/100),"unsigned":.unsignedInteger(UInt64.max-UInt64(i)),"body":.object(["index":.integer(Int64(i))])]
    if i%3==0 {result["optional"] = .null};return result
}
func rows(_ context:NSManagedObjectContext,_ predicate:NSPredicate?=nil) throws -> [NSManagedObject] {
    let r=NSFetchRequest<NSManagedObject>(entityName:"ProbeProperty");r.predicate=predicate;return try context.fetch(r)
}
func byNode(_ row:NSManagedObject)->Int { ((row.value(forKey:"node") as! NSManagedObject).value(forKey:"id") as! NSNumber).intValue }
func stamp()->Double {ProcessInfo.processInfo.systemUptime}
func diskBytes(_ root:URL)throws->Int64 {
    let urls=FileManager.default.enumerator(at:root,includingPropertiesForKeys:[.isRegularFileKey,.fileSizeKey])!
    var total:Int64=0
    for case let url as URL in urls {let v=try url.resourceValues(forKeys:[.isRegularFileKey,.fileSizeKey]);if v.isRegularFile==true {total+=Int64(v.fileSize ?? 0)}};return total
}

let operations=["equality","range","count","compound","sort","prefix","date","unsigned","count-direct","compound-staged"]
func expected(_ op:String,count:Int)->[Int] {
    let all=Array(0..<count)
    switch op {
    case "equality":return all.filter{$0%1000==42}
    case "range","count","count-direct":return all.filter{$0%1000>=990}
    case "compound","compound-staged":return all.filter{$0%1000>=990 && $0%2==0}
    case "sort":return Array(all.sorted{a,b in a%1000==b%1000 ? a<b : a%1000>b%1000}.prefix(20))
    case "prefix":return all.filter{String(format:"name%06d",$0).hasPrefix("name000")}
    case "date":return all.filter{$0>=count-10}
    default:return all.filter{$0<=9}
    }
}
func query(_ op:String,count:Int,context:NSManagedObjectContext,variant:Variant,expected:[Int])throws->(Int,Int) {
    if variant == .envelope && (op=="count-direct" || op=="compound-staged") {
        return try query(op=="count-direct" ? "count":"compound",count:count,context:context,variant:variant,expected:expected)
    }
    if variant != .envelope && op=="count-direct" {
        // One property per (owner,key) is asserted by the fixture audit, not supplied by a native unique constraint.
        let r=NSFetchRequest<NSManagedObject>(entityName:"ProbeProperty")
        r.predicate=NSPredicate(format:"name == 'score' AND tag == 2 AND integerValue >= 990")
        let n=try context.count(for:r);try require(n==expected.count,"Direct property count mismatch");return(n,0)
    }
    if variant != .envelope && op=="compound-staged" {
        let first=try rows(context,NSPredicate(format:"name == 'score' AND tag == 2 AND integerValue >= 990"))
        let owners=first.map{($0.value(forKey:"node") as! NSManagedObject).objectID}
        if owners.isEmpty {try require(expected.isEmpty,"Empty staged query mismatch");return(0,0)}
        let second=try rows(context,NSPredicate(format:"name == 'active' AND tag == 1 AND booleanValue == YES AND node IN %@",owners))
        let ids=second.map(byNode).sorted();try require(ids==expected,"Staged compound mismatch");return(ids.count,0)
    }
    if variant == .envelope {
        let keys=op=="compound" ? ["score","active"] : [op=="prefix" ? "name" : op=="date" ? "when" : op=="unsigned" ? "unsigned" : "score"]
        let data=try rows(context,NSPredicate(format:"name IN %@",keys))
        var inventory:[Int:[String:GraphValue]]=[:]
        for row in data {inventory[byNode(row),default:[:]][row.value(forKey:"name") as! String]=try get(row,variant:variant)}
        var matches:[Int]=[]
        for (id,p) in inventory {
            var match=false
            switch op {
            case "prefix":if case .string(let x)=p["name"] {match=x.hasPrefix("name000")}
            case "date":if case .date(let x)=p["when"] {match=x >= Date(timeIntervalSince1970:Double(count-10))}
            case "unsigned":if case .unsignedInteger(let x)=p["unsigned"] {match=x >= UInt64.max-9}
            default:if case .integer(let x)=p["score"] {match=op=="sort" || (op=="equality" ? x==42 : x>=990);if op=="compound" {match=match && p["active"] == .boolean(true)}}
            }
            if match {matches.append(id)}
        }
        if op=="sort" {matches.sort{a,b in
            guard case .integer(let x)=inventory[a]?["score"],case .integer(let y)=inventory[b]?["score"] else {return a<b};return x==y ? a<b:x>y
        };matches=Array(matches.prefix(20))} else {matches.sort()}
        try require(matches==expected,"Envelope result mismatch: "+op);return (matches.count,data.count)
    }
    if op=="count" || op=="compound" {
        let r=NSFetchRequest<NSManagedObject>(entityName:"ProbeNode")
        let format="SUBQUERY(properties, $p, $p.name == 'score' AND $p.tag == 2 AND $p.integerValue >= 990).@count > 0"
        r.predicate=NSPredicate(format:op=="compound" ? format+" AND SUBQUERY(properties, $q, $q.name == 'active' AND $q.tag == 1 AND $q.booleanValue == YES).@count > 0" : format)
        if op=="count" {let n=try context.count(for:r);try require(n==expected.count,"Native count mismatch");return(n,0)}
        let ids=try context.fetch(r).map{($0.value(forKey:"id") as! NSNumber).intValue}.sorted()
        try require(ids==expected,"Compound mismatch");return(ids.count,0)
    }
    let r=NSFetchRequest<NSManagedObject>(entityName:"ProbeProperty")
    switch op {
    case "equality":r.predicate=NSPredicate(format:"name == 'score' AND tag == 2 AND integerValue == 42")
    case "range":r.predicate=NSPredicate(format:"name == 'score' AND tag == 2 AND integerValue >= 990")
    case "sort":r.predicate=NSPredicate(format:"name == 'score' AND tag == 2");r.sortDescriptors=[NSSortDescriptor(key:"integerValue",ascending:false),NSSortDescriptor(key:"node.id",ascending:true)];r.fetchLimit=20
    case "prefix":r.predicate=NSPredicate(format:"name == 'name' AND tag == 6 AND textValue BEGINSWITH %@","name000")
    case "date":r.predicate=NSPredicate(format:"name == 'when' AND tag == 8 AND dateValue >= %@",Date(timeIntervalSince1970:Double(count-10)) as NSDate)
    default:r.predicate=NSPredicate(format:"name == 'unsigned' AND tag == 3 AND textValue >= %@",String(UInt64.max-9))
    }
    let found=try context.fetch(r);var ids=found.map(byNode);if op != "sort" {ids.sort()}
    try require(ids==expected,"Native result mismatch: "+op);return(ids.count,0)
}

@main struct Main {
    static func main() async {
        do {try await run()} catch {FileHandle.standardError.write(Data("Laboratory failed: \(error)\n".utf8));exit(1)}
    }
    static func run() async throws {
        let raw=Array(CommandLine.arguments.dropFirst())
        UserDefaults.standard.register(defaults:["com.apple.CoreData.SQLDebug":raw.contains("--sql-debug") ? 1:0])
        let a=raw.filter{$0 != "--sql-debug"}
        guard a.count==4,let variant=Variant(rawValue:a[0]),let count=Int(a[2]),(1...50000).contains(count),
              a[1]=="seed" || a[1]=="audit" || a[1]=="mutate" || a[1]=="verify-mutated" || operations.contains(a[1]) else {throw Failure.invalidRequest}
        let op=a[1],root=URL(fileURLWithPath:a[3],isDirectory:true),url=root.appendingPathComponent("Store.sqlite")
        GraphValueTransformer.register()
        if op=="seed" {try require(!FileManager.default.fileExists(atPath:root.path),"Fresh fixtures required");try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)}
        else {try require(FileManager.default.fileExists(atPath:url.path),"Missing fixture")}
        if op=="mutate" {try Data().write(to:root.appendingPathComponent("mutate.started"),options:.withoutOverwriting)}
        let start=stamp(),psc=NSPersistentStoreCoordinator(managedObjectModel:model(variant))
        let store=try psc.addPersistentStore(ofType:NSSQLiteStoreType,configurationName:nil,at:url,options:[NSPersistentHistoryTrackingKey:true,NSMigratePersistentStoresAutomaticallyOption:false,NSInferMappingModelAutomaticallyOption:false])
        let context=NSManagedObjectContext(concurrencyType:.privateQueueConcurrencyType);context.persistentStoreCoordinator=psc;context.undoManager=nil
        let opened=stamp()-start
        let result=try await context.perform { ()throws->[String:Double] in
            let oracle=operations.contains(op) ? expected(op,count:count):[]
            let begin=stamp()
            if op=="seed" {
                context.transactionAuthor="consumer"
                for i in 0..<count {
                    let n=NSEntityDescription.insertNewObject(forEntityName:"ProbeNode",into:context);n.setValue(i,forKey:"id");n.setValue(i%3,forKey:"kind")
                    for (key,value) in values(i) {
                        let row=NSEntityDescription.insertNewObject(forEntityName:"ProbeProperty",into:context);row.setValue(key,forKey:"name");row.setValue(n,forKey:"node");try put(value,into:row,variant:variant)
                    }
                }
                let edge=NSEntityDescription.insertNewObject(forEntityName:"ProbeNode",into:context);edge.setValue(-1,forKey:"id");edge.setValue(0,forKey:"kind")
                for (key,value) in try edgeValues() {let row=NSEntityDescription.insertNewObject(forEntityName:"ProbeProperty",into:context);row.setValue(key,forKey:"name");row.setValue(edge,forKey:"node");try put(value,into:row,variant:variant)}
                for string in decimalCases {let d=NSEntityDescription.insertNewObject(forEntityName:"ProbeDecimal",into:context);d.setValue(NSDecimalNumber(string:string),forKey:"value")}
                try context.save();return["seconds":stamp()-begin]
            }
            if op=="audit" || op=="verify-mutated" {
                try audit(context,variant:variant,count:count,mutated:op=="verify-mutated")
                let r=NSFetchRequest<NSManagedObject>(entityName:"ProbeDecimal")
                let actual=try context.fetch(r).map{($0.value(forKey:"value") as! NSDecimalNumber).decimalValue}
                let exact=actual.contains(Decimal(string:decimalCases[0])!) && actual.contains(Decimal(string:decimalCases[1])!)
                return["seconds":stamp()-begin,"nativeDecimalExact":exact ? 1:0]
            }
            if op=="mutate" {try mutate(context,variant:variant,count:count);return["seconds":stamp()-begin]}
            let (matches,decoded)=try query(op,count:count,context:context,variant:variant,expected:oracle)
            return["seconds":stamp()-begin,"matches":Double(matches),"envelopesDecoded":Double(decoded)]
        }
        await context.perform {context.reset()};try psc.remove(store)
        var usage=rusage();getrusage(RUSAGE_SELF,&usage)
        var output:[String:Any]=result;output["variant"]=variant.rawValue;output["operation"]=op;output["nodes"]=count;output["openSeconds"]=opened;output["directoryBytes"]=try diskBytes(root);output["processPeakRSSBytes"]=usage.ru_maxrss
        let data=try JSONSerialization.data(withJSONObject:output,options:[.sortedKeys]);print(String(decoding:data,as:UTF8.self))
    }
}

let decimalCases=["12345678901234567890.123456789012345678","12345678901234567890.123456789012345679"]
func edgeValues()throws->[String:GraphValue] {
    ["edge:null":.null,"edge:bool":.boolean(false),"edge:min":.integer(.min),"edge:max":.integer(.max),
     "edge:uint0":.unsignedInteger(0),"edge:uintMax":.unsignedInteger(.max),"edge:float":.floatingPoint(-0.125),
     "edge:decimal0":.decimal(Decimal(string:decimalCases[0])!),"edge:decimal1":.decimal(Decimal(string:decimalCases[1])!),
     "edge:canonical":.string("e\u{301}"),"edge:unicode":.string("é\u{0}e\u{301}🙂"),"edge:literal.%'key":.string("100%_[literal]"),
     "edge:blob":.data(Data((0..<65536).map{UInt8(truncatingIfNeeded:$0)})),
     "edge:date":.date(Date(timeIntervalSinceReferenceDate:-123.25)),"edge:url":.url(URL(string:"https://example.invalid/a%20b?q=1")!),
     "edge:uuid":.uuid(UUID(uuidString:"00112233-4455-6677-8899-AABBCCDDEEFF")!),
     "edge:array":.array([.null,.integer(4),.object(["nested":.boolean(true)])]),
     "edge:object":.object(["null":.null,"unsigned":.unsignedInteger(.max)]),
     "edge:encoded":.encoded(try GraphEncodedValue(codec:"lab.opaque",version:1,data:Data([1,2,3])))]
}
func audit(_ context:NSManagedObjectContext,variant:Variant,count:Int,mutated:Bool)throws {
    let r=NSFetchRequest<NSManagedObject>(entityName:"ProbeNode");let all=try context.fetch(r)
    try require(all.count==count+(mutated ? 0:1),"Unexpected native node count")
    var inventory:[Int:[String:GraphValue]]=[:]
    for row in try rows(context) {
        let id=byNode(row),key=row.value(forKey:"name") as! String
        try require(inventory[id]?[key]==nil,"Duplicate property")
        inventory[id,default:[:]][key]=try get(row,variant:variant)
    }
    let edges=try edgeValues()
    let mismatches=edges.keys.sorted().filter{inventory[-1]?[$0] != edges[$0]}
    try require(mismatches.isEmpty,"Roundtrip edge mismatches: " + mismatches.joined(separator:","))
    for i in 0..<count {
        if mutated && i==count-1 {try require(inventory[i]==nil,"Cascaded properties survived");continue}
        var want=values(i)
        if mutated && i==0 {want["score"] = .string("changed");want["active"] = .null;want.removeValue(forKey:"ratio");want["new.literal.%'key"] = .integer(17)}
        try require(inventory[i]==want,"Full property roundtrip mismatch at node \(i)")
    }
    let nulls=try rows(context,variant == .envelope ? NSPredicate(format:"name == 'optional'") : NSPredicate(format:"name == 'optional' AND tag == 0"))
    let expectedNulls=(0..<count).filter{(!mutated || $0 != count-1) && $0%3==0}
    try require(nulls.map(byNode).sorted()==expectedNulls,"Missing/null distinction failed")
    let relative=GraphValue.url(URL(string:"child",relativeTo:URL(string:"https://example.invalid/base/")!)!)
    let codecRelative=try GraphValueCodec.decode(GraphValueCodec.encode(relative))
    print("SEMANTICS baselineRelativeURLIdentity=\(codecRelative == relative)")
    if variant != .envelope {
        var sample=try rows(context,NSPredicate(format:"name == 'score' AND node.id == 0")).first!
        sample.setValue(999,forKey:"tag")
        var rejected=false;do {_ = try get(sample,variant:variant)} catch {rejected=true}
        try require(rejected,"Unknown discriminator accepted");context.rollback()
        sample=try rows(context,NSPredicate(format:"name == 'score' AND node.id == 0")).first!
        sample.setValue(Data([0]),forKey:"bytesValue")
        rejected=false;do {_ = try get(sample,variant:variant)} catch {rejected=true}
        try require(rejected,"Conflicting value columns accepted");context.rollback()
        sample=try rows(context,NSPredicate(format:"name == 'score' AND node.id == 0")).first!
        rejected=false;do {try put(relative,into:sample,variant:variant)} catch {rejected=true}
        try require(rejected,"Unsupported relative URL silently accepted");context.rollback()
    }
    // String equality is a semantic test, not a timing claim. Swift canonical equivalence must survive SQL.
    if variant != .envelope {
        let found=try rows(context,NSPredicate(format:"name == 'edge:canonical' AND tag == 6 AND textValue == %@","é"))
        print("SEMANTICS unicodeCanonicalEquality=\(!found.isEmpty)")
    }
}
func mutate(_ context:NSManagedObjectContext,variant:Variant,count:Int)throws {
    let zero=try rows(context,NSPredicate(format:"node.id == 0"))
    let score=zero.first{$0.value(forKey:"name") as? String == "score"}!
    try put(.integer(9999),into:score,variant:variant);context.rollback()
    let current=try rows(context,NSPredicate(format:"node.id == 0")),scoreRow=current.first{$0.value(forKey:"name") as? String == "score"}!
    try require(get(scoreRow,variant:variant) == .integer(0),"Rollback changed a value")
    context.transactionAuthor="consumer"
    try put(.string("changed"),into:scoreRow,variant:variant)
    try put(.null,into:current.first{$0.value(forKey:"name") as? String == "active"}!,variant:variant)
    context.delete(current.first{$0.value(forKey:"name") as? String == "ratio"}!)
    let added=NSEntityDescription.insertNewObject(forEntityName:"ProbeProperty",into:context);added.setValue(scoreRow.value(forKey:"node"),forKey:"node");added.setValue("new.literal.%'key",forKey:"name");try put(.integer(17),into:added,variant:variant)
    let request=NSFetchRequest<NSManagedObject>(entityName:"ProbeNode");request.predicate=NSPredicate(format:"id == %d",count-1)
    context.delete(try context.fetch(request).first!);try context.save()
    let history=NSPersistentHistoryChangeRequest.fetchHistory(after:nil as NSPersistentHistoryToken?)
    let transactions=(try context.execute(history) as! NSPersistentHistoryResult).result as! [NSPersistentHistoryTransaction]
    try require(transactions.contains{$0.author=="consumer" && ($0.changes?.contains{$0.changeType == .delete} ?? false)},"Missing authored PH deletions")
}
