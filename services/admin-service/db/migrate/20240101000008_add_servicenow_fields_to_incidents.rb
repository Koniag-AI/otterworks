class AddServicenowFieldsToIncidents < ActiveRecord::Migration[7.1]
  def change
    add_column :incidents, :servicenow_sys_id, :string
    add_column :incidents, :servicenow_number, :string
    add_column :incidents, :servicenow_instance_url, :string
    add_column :incidents, :source, :string, default: 'manual', null: false

    add_index :incidents, :servicenow_sys_id, unique: true, where: 'servicenow_sys_id IS NOT NULL'
    add_index :incidents, :source
  end
end
