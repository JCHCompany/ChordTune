import 'package:go_router/go_router.dart';
import '../features/home/presentation/pages/home_screen.dart';
import '../features/tuner/ui/tuner_screen.dart';
import '../features/research/ui/research_screen.dart';
import '../features/guided_tuner/guided_tuner_page.dart';

GoRouter createRouter() => GoRouter(
      routes: <RouteBase>[
        GoRoute(
          path: '/',
          name: 'home',
          pageBuilder: (context, state) => const NoTransitionPage(
            child: HomeScreen(),
          ),
        ),
        GoRoute(
          path: '/tuner',
          name: 'tuner',
          pageBuilder: (context, state) => const NoTransitionPage(
            child: TunerScreen(),
          ),
        ),
        GoRoute(
          path: '/research',
          name: 'research',
          pageBuilder: (context, state) => const NoTransitionPage(
            child: ResearchScreen(),
          ),
        ),
        GoRoute(
          path: '/guided',
          name: 'guided',
          pageBuilder: (context, state) => const NoTransitionPage(
            child: GuidedTunerPage(),
          ),
        ),
      ],
    );
