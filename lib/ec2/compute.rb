require 'right_aws_api'

class ::EC2::Compute

  attr_reader :manager

  def initialize(manager)
    @manager = manager
  end

  def permission?
    begin
      manager.DescribeInstances('DryRun' => true)
      manager.RunInstances('DryRun' => true)
      manager.TerminateInstances('DryRun' => true)
    rescue RightScale::CloudApi::HttpError => e
      if not e.message =~ /DryRunOperation/
        raise
      end
    end
  end

  def instances
    list = []

    # filter the collection to just microbox instances
    filter = [{'Name'  => 'tag:Microbox', 'Value' => 'true'}]

    # query the api
    res = manager.DescribeInstances('Filter' => filter)

    # extract the instance collection
    instances = res["DescribeInstancesResponse"]["reservationSet"]

    # short-circuit if the collection is empty
    return [] if instances.nil?

    # instances might not be a collection, but a single item
    collection = begin
      if instances['item'].is_a? Array
        instances['item']
      else
        [instances['item']]
      end
    end

    # grab the instances and process them
    collection.each do |instance|
      list << process_instance(instance["instancesSet"]["item"])
    end

    list
  end

  def instance(id)
    # query the api
    res = manager.DescribeInstances('InstanceId' => id)

    # extract the instance collection
    instances = res["DescribeInstancesResponse"]["reservationSet"]

    # short-circuit if the collection is empty
    return nil if instances.nil?

    # grab the fist instance and process it
    process_instance(instances["item"]["instancesSet"]["item"])
  end

  # Run an on-demand compute instance
  #
  # attrs:
  #   name:               microbox-specific name of instance
  #   size:               instance type/size (t2.micro etc)
  #   disk:               size of disk for ebs volume
  #   ami:                amazon machine image to use to launch instance
  #   availability_zone:  availability zone to run instance on
  #   key:                id of ssh key
  #   security_group:     id of security group
  def run_instance(attrs)

    # launch the instance
    res = manager.RunInstances(
      'ImageId'            => attrs[:ami],
      'MinCount'           => 1,
      'MaxCount'           => 1,
      'KeyName'            => attrs[:key],
      'InstanceType'       => attrs[:size],
      'SecurityGroupId'    => [attrs[:security_group]],
      'Placement'          => {
         'AvailabilityZone' => attrs[:availability_zone],
         'Tenancy'          => 'default' },
      'BlockDeviceMapping' => [
        { 'DeviceName' => '/dev/sda1',
          'Ebs'        => {
           'VolumeType'          => 'gp2',
           'VolumeSize'          => attrs[:disk],
           'DeleteOnTermination' => true}} ]
    )

    # extract the instance
    instance = process_instance(res["RunInstancesResponse"]["instancesSet"]["item"])

    # name the instance
    set_instance_name(instance[:id], attrs[:name])

    # now update the name and return it
    instance.tap do |i|
      i[:name] = attrs[:name]
    end
  end

  def reboot_instance(id)
    res = manager.RebootInstances( "InstanceId" => id )
  end

  def terminate_instance(id)
    # todo: catch error?
    res = manager.TerminateInstances( "InstanceId" => id )
    res["TerminateInstancesResponse"]["instancesSet"]["item"]["currentState"]["name"]
  end

  def set_instance_name(id, name)
    # set tags
    res = manager.CreateTags(
      'ResourceId'  => id,
      'Tag' => [
        {
          'Key' => 'Microbox',
          'Value' => 'true'
        },
        {
          'Key' => 'Name',
          'Value' => name
        },
        {
          'Key' => 'Microbox-Name',
          'Value' => name
        }
      ]
    )
  end

  def availability_zones
    # Ultimately, we only want the availability_zones that are available to
    # this account AND have a default subnet. Querying the subnets for
    # default-for-az finds this list pretty quickly

    # filter the collection to just microbox instances
    filter = [{'Name'  => 'default-for-az', 'Value' => 'true'}]

    # query the api
    res = manager.DescribeSubnets('Filter' => filter)

    subnets = res['DescribeSubnetsResponse']['subnetSet']

    # if we don't have any default subnets, let's return an empty set
    return [] if subnets.nil?

    # subnets might not be a collection, but a single item
    collection = begin
      if subnets['item'].is_a? Array
        subnets['item']
      else
        [subnets['item']]
      end
    end

    availability_zones = []

    collection.each do |subnet|
      availability_zones << subnet['availabilityZone']
    end

    availability_zones.uniq.sort
  end

  private

  def process_instance(data)
    {
      id: data['instanceId'],
      name: (process_tag(data['tagSet']['item'], 'Microbox-Name') rescue 'unknown'),
      status: translate_status(data['instanceState']['name']),
      external_ip: data['ipAddress'],
      internal_ip: data['privateIpAddress']
    }
  end

  def process_tag(tags, key)
    tags.each do |tag|
      if tag['key'] == key
        return tag['value']
      end
    end
    ''
  end

  def translate_status(status)
    case status
    when 'running'
      'active'
    else
      status
    end
  end

end
