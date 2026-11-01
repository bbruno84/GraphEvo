import CoreData
import Foundation
let root=FileManager.default.temporaryDirectory.appendingPathComponent("TypedNUL-"+UUID().uuidString)
try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
let entity=NSEntityDescription();entity.name="TextProbe";entity.managedObjectClassName="NSManagedObject"
let a=NSAttributeDescription();a.name="text";a.attributeType = .stringAttributeType;entity.properties=[a]
let model=NSManagedObjectModel();model.entities=[entity]
let psc=NSPersistentStoreCoordinator(managedObjectModel:model)
let store=try psc.addPersistentStore(ofType:NSSQLiteStoreType,configurationName:nil,at:root.appendingPathComponent("Store.sqlite"))
let context=NSManagedObjectContext(concurrencyType:.mainQueueConcurrencyType);context.persistentStoreCoordinator=psc
let expected="é\u{0}e\u{301}🙂"
let row=NSEntityDescription.insertNewObject(forEntityName:"TextProbe",into:context);row.setValue(expected,forKey:"text");try context.save();context.reset()
let actual=try context.fetch(NSFetchRequest<NSManagedObject>(entityName:"TextProbe")).first!.value(forKey:"text") as! String
print("Expected Unicode scalars:",expected.unicodeScalars.map{$0.value})
print("Actual Unicode scalars:",actual.unicodeScalars.map{$0.value})
context.reset();try psc.remove(store)
