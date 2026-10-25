# The normal project remains unmodified and excludes AI model/runtime resources.
require 'yaml'
require 'pathname'
root = Pathname.new(__dir__).parent
config = YAML.safe_load((root + 'project.yml').read, aliases: true)
config.fetch('settings').fetch('base')['MARKETING_VERSION'] = '0.3.2'
config.fetch('settings').fetch('base')['CURRENT_PROJECT_VERSION'] = '3'
target = config.fetch('targets').fetch('Fusion')
base = target.fetch('settings').fetch('base')
base['GCC_PREPROCESSOR_DEFINITIONS'] = '$(inherited) FUSION_AI_VOICE=1'
base['HEADER_SEARCH_PATHS'] += ' $(SRCROOT)/Vendor/onnxruntime/unpacked/Headers'
base['OTHER_LDFLAGS'] += ' -lc++ -framework Accelerate -framework CoreML'
base['PRODUCT_BUNDLE_IDENTIFIER'] = 'com.bilifusion.ios.ai'
target.fetch('info').fetch('properties')['CFBundleIdentifier'] = 'com.bilifusion.ios.ai'
target.fetch('info').fetch('properties')['CFBundleDisplayName'] = '二路随行·AI去人声'
target.fetch('sources') << {'path'=>'AIAssets','type'=>'folder','buildPhase'=>'resources'}
target.fetch('dependencies') << {'framework'=>'Vendor/onnxruntime/unpacked/onnxruntime.xcframework','embed'=>false,'link'=>true}
# XCTest compiles its own bridging-header macros, so tests may query the C stubs.
(root + 'project-ai.yml').write(YAML.dump(config))
