import CoreMediaIO
import Foundation

let providerSource = PhoneLensCameraProvider(clientQueue: nil)
CMIOExtensionProvider.startService(provider: providerSource.provider)
CFRunLoopRun()
