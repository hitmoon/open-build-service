class PackageUpdateIfDirtyJob < ApplicationJob
  def perform(package_id)
    package = Package.find(package_id)
    package.update_if_dirty if package.present?
  end
end
