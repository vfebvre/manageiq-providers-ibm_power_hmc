FactoryBot.define do
  factory :ibm_power_hmc_resource_pool,
          :aliases => ["manageiq/providers/ibm_power_hmc/infra_manager/resource_pool"],
          :class   => "ManageIQ::Providers::IbmPowerHmc::InfraManager::ResourcePool",
          :parent  => :resource_pool
end
