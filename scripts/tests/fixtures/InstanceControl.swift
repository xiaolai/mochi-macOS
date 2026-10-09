import Foundation
let arguments = CommandLine.arguments
DistributedNotificationCenter.default().postNotificationName(Notification.Name("mochi.e2e.command"),object:arguments[1],userInfo:["command":arguments[2]],deliverImmediately:true)
