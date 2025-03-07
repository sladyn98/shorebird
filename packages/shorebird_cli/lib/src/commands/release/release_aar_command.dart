import 'dart:async';
import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:collection/collection.dart';
import 'package:crypto/crypto.dart';
import 'package:mason_logger/mason_logger.dart';
import 'package:path/path.dart' as p;
import 'package:shorebird_cli/src/command.dart';
import 'package:shorebird_cli/src/config/config.dart';
import 'package:shorebird_cli/src/shorebird_artifact_mixin.dart';
import 'package:shorebird_cli/src/shorebird_build_mixin.dart';
import 'package:shorebird_cli/src/shorebird_config_mixin.dart';
import 'package:shorebird_cli/src/shorebird_create_app_mixin.dart';
import 'package:shorebird_cli/src/shorebird_java_mixin.dart';
import 'package:shorebird_cli/src/shorebird_release_version_mixin.dart';
import 'package:shorebird_cli/src/shorebird_validation_mixin.dart';
import 'package:shorebird_code_push_client/shorebird_code_push_client.dart';

/// {@template release_aar_command}
/// `shorebird release aar`
/// Create new Android archive releases.
/// {@endtemplate}
class ReleaseAarCommand extends ShorebirdCommand
    with
        ShorebirdConfigMixin,
        ShorebirdValidationMixin,
        ShorebirdBuildMixin,
        ShorebirdCreateAppMixin,
        ShorebirdJavaMixin,
        ShorebirdReleaseVersionMixin,
        ShorebirdArtifactMixin {
  /// {@macro release_aar_command}
  ReleaseAarCommand({
    required super.logger,
    super.auth,
    super.buildCodePushClient,
    super.validators,
    HashFunction? hashFn,
    UnzipFn? unzipFn,
  })  : _hashFn = hashFn ?? ((m) => sha256.convert(m).toString()),
        _unzipFn = unzipFn ?? extractFileToDisk {
    argParser
      ..addOption(
        'release-version',
        help: '''
The version of the associated release (e.g. "1.0.0"). This should be the version
of the Android app that is using this module.''',
        mandatory: true,
      )
      ..addOption(
        'flavor',
        help: 'The product flavor to use when building the app.',
      )
      // `flutter build aar` defaults to a build number of 1.0, so we do the
      // same.
      ..addOption(
        'build-number',
        help: 'The build number of the aar',
        defaultsTo: '1.0',
      )
      ..addFlag(
        'force',
        abbr: 'f',
        help: 'Release without confirmation if there are no errors.',
        negatable: false,
      );
  }

  @override
  String get name => 'aar';

  @override
  String get description => '''
Builds and submits your Android archive to Shorebird.
Shorebird saves the compiled Dart code from your application in order to
make smaller updates to your app.
''';

  final HashFunction _hashFn;
  final UnzipFn _unzipFn;

  @override
  Future<int> run() async {
    try {
      await validatePreconditions(
        checkUserIsAuthenticated: true,
        checkShorebirdInitialized: true,
        checkValidators: true,
      );
    } on PreconditionFailedException catch (e) {
      return e.exitCode.code;
    }

    if (androidPackageName == null) {
      logger.err('Could not find androidPackage in pubspec.yaml.');
      return ExitCode.config.code;
    }

    final flavor = results['flavor'] as String?;
    final buildNumber = results['build-number'] as String;
    final releaseVersion = results['release-version'] as String;
    final buildProgress = logger.progress('Building aar');
    try {
      await buildAar(buildNumber: buildNumber, flavor: flavor);
    } on ProcessException catch (error) {
      buildProgress.fail('Failed to build: ${error.message}');
      return ExitCode.software.code;
    }

    buildProgress.complete();

    final shorebirdYaml = getShorebirdYaml()!;
    final codePushClient = buildCodePushClient(
      httpClient: auth.client,
      hostedUri: hostedUri,
    );

    late final List<App> apps;
    final fetchAppsProgress = logger.progress('Fetching apps');
    try {
      apps = (await codePushClient.getApps())
          .map((a) => App(id: a.appId, displayName: a.displayName))
          .toList();
      fetchAppsProgress.complete();
    } catch (error) {
      fetchAppsProgress.fail('$error');
      return ExitCode.software.code;
    }

    final appId = shorebirdYaml.getAppId(flavor: flavor);
    final app = apps.firstWhereOrNull((a) => a.id == appId);
    if (app == null) {
      logger.err(
        '''
Could not find app with id: "$appId".
Did you forget to run "shorebird init"?''',
      );
      return ExitCode.software.code;
    }

    const platform = 'android';
    final archNames = architectures.keys.map(
      (arch) => arch.name,
    );
    final summary = [
      '''📱 App: ${lightCyan.wrap(app.displayName)} ${lightCyan.wrap('(${app.id})')}''',
      if (flavor != null) '🍧 Flavor: ${lightCyan.wrap(flavor)}',
      '📦 Release Version: ${lightCyan.wrap(releaseVersion)}',
      '''🕹️  Platform: ${lightCyan.wrap(platform)} ${lightCyan.wrap('(${archNames.join(', ')})')}''',
    ];

    logger.info('''

${styleBold.wrap(lightGreen.wrap('🚀 Ready to create a new release!'))}

${summary.join('\n')}
''');

    final force = results['force'] == true;
    final needConfirmation = !force;
    if (needConfirmation) {
      final confirm = logger.confirm('Would you like to continue?');

      if (!confirm) {
        logger.info('Aborting.');
        return ExitCode.success.code;
      }
    }

    late final List<Release> releases;
    final fetchReleasesProgress = logger.progress('Fetching releases');
    try {
      releases = await codePushClient.getReleases(appId: app.id);
      fetchReleasesProgress.complete();
    } catch (error) {
      fetchReleasesProgress.fail('$error');
      return ExitCode.software.code;
    }

    var release = releases.firstWhereOrNull((r) => r.version == releaseVersion);
    if (release == null) {
      final flutterRevisionProgress = logger.progress(
        'Fetching Flutter revision',
      );
      final String shorebirdFlutterRevision;
      try {
        shorebirdFlutterRevision = await getShorebirdFlutterRevision();
        flutterRevisionProgress.complete();
      } catch (error) {
        flutterRevisionProgress.fail('$error');
        return ExitCode.software.code;
      }

      final createReleaseProgress = logger.progress('Creating release');
      try {
        release = await codePushClient.createRelease(
          appId: app.id,
          version: releaseVersion,
          flutterRevision: shorebirdFlutterRevision,
        );
        createReleaseProgress.complete();
      } catch (error) {
        createReleaseProgress.fail('$error');
        return ExitCode.software.code;
      }
    }

    final createArtifactProgress = logger.progress('Creating artifacts');

    final extractedAarDir = await extractAar(
      packageName: androidPackageName!,
      buildNumber: buildNumber,
      unzipFn: _unzipFn,
    );

    for (final archMetadata in architectures.values) {
      final artifactPath = p.join(
        extractedAarDir,
        'jni',
        archMetadata.path,
        'libapp.so',
      );
      final artifact = File(artifactPath);
      final hash = _hashFn(await artifact.readAsBytes());
      logger.detail('Creating artifact for $artifactPath');

      try {
        await codePushClient.createReleaseArtifact(
          releaseId: release.id,
          artifactPath: artifact.path,
          arch: archMetadata.arch,
          platform: platform,
          hash: hash,
        );
      } on CodePushConflictException catch (_) {
        // Newlines are due to how logger.info interacts with logger.progress.
        logger.info(
          '''

${archMetadata.arch} artifact already exists, continuing...''',
        );
      } catch (error) {
        createArtifactProgress.fail('Error uploading ${artifact.path}: $error');
        return ExitCode.software.code;
      }
    }

    final aarPath = aarArtifactPath(
      packageName: androidPackageName!,
      buildNumber: buildNumber,
    );
    try {
      logger.detail('Creating artifact for $aarPath');
      await codePushClient.createReleaseArtifact(
        releaseId: release.id,
        artifactPath: aarPath,
        arch: 'aar',
        platform: platform,
        hash: _hashFn(await File(aarPath).readAsBytes()),
      );
    } on CodePushConflictException catch (_) {
      // Newlines are due to how logger.info interacts with logger.progress.
      logger.info(
        '''

aar artifact already exists, continuing...''',
      );
    } catch (error) {
      createArtifactProgress.fail('Error uploading $aarPath: $error');
      return ExitCode.software.code;
    }

    createArtifactProgress.complete();

    logger
      ..success('\n✅ Published Release!')
      ..info('''

Your next step is to add this module as a dependency in your app's build.gradle:
${lightCyan.wrap('''
dependencies {
  // ...
  releaseImplementation '$androidPackageName:flutter_release:$buildNumber'
  // ...
}''')}
''');

    return ExitCode.success.code;
  }
}
