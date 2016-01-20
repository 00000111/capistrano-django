namespace :python do

  def virtualenv_path
    File.join(
      fetch(:shared_virtualenv) ? shared_path : release_path, "virtualenv"
    )
  end

  desc "Create a python virtualenv"
  task :create_virtualenv do
    on roles(:all) do |h|
      if test("[ -d #{virtualenv_path} ]")
        execute "source #{virtualenv_path}/bin/activate"
      else
        execute "virtualenv #{virtualenv_path}"
      end
      execute "#{virtualenv_path}/bin/pip install -r #{release_path}/#{fetch(:pip_requirements)}"
      if fetch(:shared_virtualenv)
        execute :ln, "-s", virtualenv_path, File.join(release_path, 'virtualenv')
      end
    end

    if fetch(:npm_tasks)
      invoke 'nodejs:npm'
    end
    if fetch(:flask)
      invoke 'flask:setup'
    else
      invoke 'django:setup'
    end
  end

end

namespace :flask do

  task :setup do
    on roles(:web) do |h|
      execute "ln -s #{release_path}/settings/#{fetch(:settings_file)}.py #{release_path}/settings/deployed.py"
      execute "ln -sf #{release_path}/wsgi/wsgi.py #{release_path}/wsgi/live.wsgi"
    end
  end

end

namespace :django do

  def django(args, flags="", run_on=:all)
    on roles(run_on) do |h|
      manage_path = File.join(release_path, fetch(:django_project_dir) || '', 'manage.py')
      execute "#{release_path}/virtualenv/bin/envdir #{release_path}/envdir/#{fetch(:stage)} #{release_path}/virtualenv/bin/python #{manage_path} #{fetch(:django_settings)} #{args} #{flags}"
    end
  end

  desc "Setup Django environment"
  task :setup do
    if fetch(:django_compressor)
      invoke 'django:compress'
    end
    invoke 'django:compilemessages'
    invoke 'django:collectstatic'
    invoke 'django:rebuild_index'
    # invoke 'django:symlink_settings'
    if !fetch(:nginx)
      invoke 'django:symlink_wsgi'
    end
    invoke 'django:migrate'
  end

  desc "Compile Messages"
  task :compilemessages do
    if fetch :compilemessages
      django("compilemessages")
    end
  end

  desc "Restart Celery"
  task :restart_celery do
    if fetch(:celery_name)
      invoke 'django:restart_celeryd'
      invoke 'django:restart_celerybeat'
    end
    if fetch(:celery_names)
      invoke 'django:restart_named_celery_processes'
    end
  end

  desc "Update Supervisor config"
  task :update_supervisor_config do
    "#{release_path}/virtualenv/bin/envdir #{release_path}/envdir/#{fetch(:stage)} /opt/chef/embedded/bin/erb #{release_path}/conf.d/supervisor/%s.conf.erb > /etc/supervisor/conf.d/%s.conf; % (SUPERVISOR_APP_NAME,SUPERVISOR_APP_NAME)"
  end

  desc "Update Nginx config"
  task :update_nginx_config do
    "#{release_path}/virtualenv/bin/envdir #{release_path}/envdir/#{fetch(:stage)} /opt/chef/embedded/bin/erb #{release_path}/conf.d/nginx/%s.conf.erb > /etc/nginx/sites-enabled/%s.conf; % (SUPERVISOR_APP_NAME,SUPERVISOR_APP_NAME)"
  end

  desc "Supervisor reload"
  task :supervisor_reload do
    execute 'sudo supervisorctl reread'
    execute 'sudo supervisorctl update'
  end

  desc "Nginx reload"
  task :nginx_reload do
    execute 'sudo service nginx reload'
  end

  desc "Restart Celeryd"
  task :restart_celeryd do
    on roles(:jobs) do
      execute "sudo service celeryd-#{fetch(:celery_name)} restart"
    end
  end

  desc "Restart Celerybeat"
  task :restart_celerybeat do
    on roles(:jobs) do
      execute "sudo service celerybeat-#{fetch(:celery_name)} restart"
    end
  end

  desc "Restart named celery processes"
  task :restart_named_celery_processes do
    on roles(:jobs) do
      fetch(:celery_names).each { | celery_name, celery_beat |
        execute "sudo service celeryd-#{celery_name} restart"
        if celery_beat
          execute "sudo service celerybeat-#{celery_name} restart"
        end
      }
    end
  end

  desc "Run django-compressor"
  task :compress do
    django("compress")
  end

  desc "Run django's collectstatic"
  task :collectstatic do
    if fetch(:create_s3_bucket)
      invoke 's3:create_bucket'
      on roles(:web) do
        django("collectstatic", "-i *.coffee -i *.less -i node_modules/* -i bower_components/* --noinput --clear")
      end
    else
      on roles(:migrator) do
        django("collectstatic", "-i *.coffee -i *.less -i node_modules/* -i bower_components/* --noinput")
      end
    end
  end

  desc "Symlink django settings to deployed.py"
  task :symlink_settings do
    settings_path = File.join(release_path, fetch(:django_settings_dir))
    on roles(:all) do
      execute "ln -s #{settings_path}/#{fetch(:django_settings)}.py #{settings_path}/deployed.py"
    end
  end

  desc "Symlink wsgi script to live.wsgi"
  task :symlink_wsgi do
    on roles(:web) do
      wsgi_path = File.join(release_path, fetch(:wsgi_path, 'wsgi'))
      wsgi_file_name = fetch(:wsgi_file_name, 'main.wsgi')
      execute "ln -sf #{wsgi_path}/#{wsgi_file_name} #{wsgi_path}/live.wsgi"
    end
  end

  desc "Run django migrations"
  task :migrate do
    on roles(:migrator) do
      if fetch(:multidb)
        django('sync_all', '--noinput', run_on=:web)
      else
        django('migrate', '--noinput', run_on=:web)
      end
    end
  end

  task :rebuild_index do
    django("rebuild_index", "--noinput", run_on=:web)
  end
end

namespace :nodejs do

  desc 'Install node modules'
  task :npm_install do
    on roles(:web) do
      path = fetch(:npm_path) ? File.join(release_path, fetch(:npm_path)) : release_path
      within path do
        execute 'npm', 'install'
      end
    end
  end

  desc 'Run npm tasks'
  task :npm do
    invoke 'nodejs:npm_install'
    on roles(:web) do
      path = fetch(:npm_path) ? File.join(release_path, fetch(:npm_path)) : release_path
      within path do
        fetch(:npm_tasks).each do |task, args|
          execute "#{task}", args
        end
      end
    end
  end

end


before 'deploy:cleanup', 's3:cleanup'

namespace :s3 do

  desc 'Clean up old s3 buckets'
  task :cleanup do
    if fetch(:create_s3_bucket)
      on roles(:web) do
        releases = capture(:ls, '-xtr', releases_path).split
        if releases.count >= fetch(:keep_releases)
          directories = releases.last(fetch(:keep_releases))
          require 'fog'
          storage = Fog::Storage.new({
            aws_access_key_id: fetch(:aws_access_key),
            aws_secret_access_key: fetch(:aws_secret_key),
            provider: "AWS"
          })
          buckets = storage.directories.all.select { |b| b.key.start_with? fetch(:s3_bucket_prefix) }
          buckets = buckets.select { |b| not directories.include?(b.key.split('-').last) }
          buckets.each do |old_bucket|
            files = old_bucket.files.map{ |file| file.key }
            storage.delete_multiple_objects(old_bucket.key, files) unless files.empty?
            storage.delete_bucket(old_bucket.key)
          end
        end
      end
    end
  end

  desc 'Create a new bucket in s3 to deploy static files to'
  task :create_bucket do
    settings_path = File.join(release_path, fetch(:django_settings_dir))
    s3_settings_path = File.join(settings_path, 's3_settings.py')
    bucket_name = "#{fetch(:s3_bucket_prefix)}-#{asset_timestamp.sub('.', '')}"

    on roles(:all) do
      execute %Q|echo "STATIC_URL = 'https://s3.amazonaws.com/#{bucket_name}/'" > #{s3_settings_path}|
      execute %Q|echo "AWS_ACCESS_KEY_ID = '#{fetch(:aws_access_key)}'" >> #{s3_settings_path}|
      execute %Q|echo "AWS_SECRET_ACCESS_KEY = '#{fetch(:aws_secret_key)}'" >> #{s3_settings_path}|
      execute %Q|echo "AWS_STORAGE_BUCKET_NAME = '#{bucket_name}'" >> #{s3_settings_path}|
      execute %Q|echo 'from .s3_settings import *' >> #{settings_path}/#{fetch(:django_settings)}.py|
      execute %Q|echo 'STATICFILES_STORAGE = "storages.backends.s3boto.S3BotoStorage"' >> #{settings_path}/#{fetch(:django_settings)}.py|
    end

    require 'fog'
    storage = Fog::Storage.new({
      aws_access_key_id: fetch(:aws_access_key),
      aws_secret_access_key: fetch(:aws_secret_key),
      provider: "AWS"
    })
    storage.put_bucket(bucket_name)
    storage.put_bucket_policy(bucket_name, {
      'Statement' => [{
      'Sid' => 'AddPerm',
      'Effect' => 'Allow',
      'Principal' => '*',
      'Action' => ['s3:GetObject'],
      'Resource' => ["arn:aws:s3:::#{bucket_name}/*"]
      }]
    })
    storage.put_bucket_cors(bucket_name, {
      "CORSConfiguration" => [{
        "AllowedOrigin" => ["*"],
        "AllowedHeader" => ["*"],
        "AllowedMethod" => ["GET"],
        "MaxAgeSeconds" => 3000
      }]
    })

  end

end

namespace :db do
  task :sync do
    on roles(:sync) do
      timestamp = Time.now.to_i
      database_url = File.read('envdir/uat/DATABASE_URL').strip
      uri = URI.parse(database_url)
      username = uri.user
      password = uri.password
      host = uri.host
      port = uri.port
      database = (uri.path || "").split("/")[1]
      execute "PGPASSWORD='#{password}' pg_dump -U #{username} -h #{host} #{database}  > /tmp/uat-#{timestamp}.dump"
      database_url = File.read('envdir/prod/DATABASE_URL').strip
      uri = URI.parse(database_url)
      username = uri.user
      password = uri.password
      host = uri.host
      port = uri.port
      database = (uri.path || "").split("/")[1]
      execute "PGPASSWORD='#{password}' pg_dump -U #{username} -h #{host} #{database} > /tmp/prod-#{timestamp}.dump"
      execute "PGPASSWORD='#{password}' dropdb -U #{username} -h #{host} #{database}"
      execute "PGPASSWORD='#{password}' createdb -U #{username} -O #{username} -h #{host} #{database}"
      execute "PGPASSWORD='#{password}' psql -U #{username} -h #{host} #{database} < /tmp/uat-#{timestamp}.dump"
    end
  end
  task :sync_to_uat do
    on roles(:sync) do
      timestamp = Time.now.to_i
      database_url = File.read('envdir/prod/DATABASE_URL').strip
      uri = URI.parse(database_url)
      username = uri.user
      password = uri.password
      host = uri.host
      port = uri.port
      database = (uri.path || "").split("/")[1]
      execute "PGPASSWORD='#{password}' pg_dump -U #{username} -h #{host} #{database}  > /tmp/prod-#{timestamp}.dump"
      database_url = File.read('envdir/uat/DATABASE_URL').strip
      uri = URI.parse(database_url)
      username = uri.user
      password = uri.password
      host = uri.host
      port = uri.port
      database = (uri.path || "").split("/")[1]
      execute "PGPASSWORD='#{password}' pg_dump -U #{username} -h #{host} #{database} > /tmp/uat-#{timestamp}.dump"
      execute "PGPASSWORD='#{password}' dropdb -U #{username} -h #{host} #{database}"
      execute "PGPASSWORD='#{password}' createdb -U #{username} -O #{username} -h #{host} #{database}"
      execute "PGPASSWORD='#{password}' psql -U #{username} -h #{host} #{database} < /tmp/prod-#{timestamp}.dump"
    end
  end
end

namespace :s3 do
  task :sync do
    on roles(:sync) do
      aws_access_key_id = File.read('envdir/prod/DJANGO_AWS_ACCESS_KEY_ID').strip
      aws_secret_access_key = File.read('envdir/prod/DJANGO_AWS_SECRET_ACCESS_KEY').strip
      uat_storage = File.read('envdir/uat/DJANGO_AWS_STORAGE_BUCKET_NAME').strip
      uat_static_storage = File.read('envdir/uat/DJANGO_AWS_STATIC_STORAGE_BUCKET_NAME').strip
      prod_storage = File.read('envdir/prod/DJANGO_AWS_STORAGE_BUCKET_NAME').strip
      prod_static_storage = File.read('envdir/prod/DJANGO_AWS_STATIC_STORAGE_BUCKET_NAME').strip
      require 'aws-sdk'
      s3 = Aws::S3::Resource.new(
        region: 'us-east-1',
        credentials:
          Aws::Credentials.new(
            aws_access_key_id,
            aws_secret_access_key
          )
      )

      bucket = s3.bucket(uat_storage)
      bucket.objects.each do |object_sum|
        object = bucket.object(object_sum.key)
        puts "Copying: #{object_sum.key}"
        object.copy_to("#{prod_storage}/#{object_sum.key}", acl: 'public-read', metadata_directive: 'REPLACE')
      end
    end
  end
  task :sync_to_uat do
    on roles(:sync) do
      aws_access_key_id = File.read('envdir/prod/DJANGO_AWS_ACCESS_KEY_ID').strip
      aws_secret_access_key = File.read('envdir/prod/DJANGO_AWS_SECRET_ACCESS_KEY').strip
      uat_storage = File.read('envdir/uat/DJANGO_AWS_STORAGE_BUCKET_NAME').strip
      prod_storage = File.read('envdir/prod/DJANGO_AWS_STORAGE_BUCKET_NAME').strip
      require 'aws-sdk'
      s3 = Aws::S3::Resource.new(
        region: 'us-east-1',
        credentials:
          Aws::Credentials.new(
            aws_access_key_id,
            aws_secret_access_key
          )
      )

      bucket = s3.bucket(prod_storage)
      bucket.objects.each do |object_sum|
        object = bucket.object(object_sum.key)
        puts "Copying: #{object_sum.key}"
        object.copy_to("#{uat_storage}/#{object_sum.key}", acl: 'public-read', metadata_directive: 'REPLACE')
      end
    end
  end
end

namespace :sync do
  desc 'Sync UAT to PROD'
  task :uat_to_prod do
    invoke 's3:sync'
    invoke 'db:sync'
    invoke 'deploy'
  end

  desc 'Sync UAT to PROD'
  task :prod_to_uat do
    invoke 's3:sync_to_uat'
    invoke 'db:sync_to_uat'
  end
end

after 'deploy:updating', 'python:create_virtualenv'
after 'deploy:restart', 'django:restart_celery'
