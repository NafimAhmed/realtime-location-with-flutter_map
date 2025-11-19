import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';
import 'package:http/http.dart' as http;

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const MyApp());
}

/// ===================== ROOT APP =====================
class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Realtime + Search (flutter_map)',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorSchemeSeed: const Color(0xFFFF7A00),
        useMaterial3: true,
      ),
      home: const RealtimeSearchMapPage(),
    );
  }
}

/// ===================== LOCAL MODEL FOR SEARCH RESULT =====================
class _PlaceResult {
  final String name;
  final LatLng coord;
  const _PlaceResult({required this.name, required this.coord});
}

/// ===================== PAGE =====================
class RealtimeSearchMapPage extends StatefulWidget {
  const RealtimeSearchMapPage({super.key});

  @override
  State<RealtimeSearchMapPage> createState() => _RealtimeSearchMapPageState();
}

class _RealtimeSearchMapPageState extends State<RealtimeSearchMapPage> {
  final MapController _mapController = MapController();

  // Initial center (Dhaka)
  LatLng _center = LatLng(23.7808, 90.2794);
  double _zoom = 13;

  /// ✅ Realtime "Me" location
  LatLng? _myLocation;
  StreamSubscription<Position>? _positionSub;
  bool _followMe = true;

  /// 🔍 Search
  final TextEditingController _searchController = TextEditingController();
  bool _searching = false;
  String? _errorText;

  List<_PlaceResult> _searchResults = [];
  LatLng? _searchedLocation; // marker for searched place

  /// ➕ Route points: amar location theke destination porjonto (road-follow)
  List<LatLng> _routePoints = [];

  /// ➕ Live movement trail: ami jekhane jekhane gesi oitar line
  List<LatLng> _myTrail = [];

  @override
  void initState() {
    super.initState();
    _initMyLocationStream();
  }

  @override
  void dispose() {
    _positionSub?.cancel();
    _searchController.dispose();
    super.dispose();
  }

  /// ---------- LOCATION PERMISSION HELPER ----------
  Future<bool> _ensureLocationPermission() async {
    try {
      final serviceEnabled = await Geolocator.isLocationServiceEnabled();
      if (!serviceEnabled) {
        if (!mounted) return false;
        setState(() {
          _errorText =
          "Location service off ache.\nPlease GPS on kore abar try korun.";
        });
        return false;
      }

      LocationPermission permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
      }

      if (permission == LocationPermission.denied ||
          permission == LocationPermission.deniedForever) {
        if (!mounted) return false;
        setState(() {
          _errorText =
          "Location permission deny kora.\nApp setting theke allow korun.";
        });
        return false;
      }

      if (!mounted) return true;
      setState(() {
        _errorText = null;
      });
      return true;
    } on PermissionDefinitionsNotFoundException {
      if (!mounted) return false;
      setState(() {
        _errorText =
        "AndroidManifest.xml e location permissions define kora nai.\n"
            "Add kore dao:\n"
            "<uses-permission android:name=\"android.permission.ACCESS_FINE_LOCATION\" />\n"
            "<uses-permission android:name=\"android.permission.ACCESS_COARSE_LOCATION\" />";
      });
      return false;
    } on LocationServiceDisabledException {
      if (!mounted) return false;
      setState(() {
        _errorText = "Location service disabled.\nGPS on kore abar try korun.";
      });
      return false;
    } catch (e) {
      if (!mounted) return false;
      setState(() {
        _errorText = "Location permission error: $e";
      });
      return false;
    }
  }

  /// ---------- 🧠 ROUTE BUILD (OSRM diye) ----------
  Future<void> _buildRoute() async {
    if (_myLocation == null || _searchedLocation == null) {
      if (!mounted) return;
      setState(() {
        _routePoints = [];
      });
      return;
    }

    final start = _myLocation!;
    final dest = _searchedLocation!;

    try {
      // OSRM public demo server (driving)
      final url = Uri.parse(
        'https://router.project-osrm.org/route/v1/driving'
            '/${start.longitude},${start.latitude};${dest.longitude},${dest.latitude}'
            '?overview=full&geometries=geojson',
      );

      final resp = await http.get(url);

      if (resp.statusCode != 200) {
        throw Exception('OSRM HTTP ${resp.statusCode}');
      }

      final body = json.decode(resp.body);
      if (body['routes'] == null ||
          (body['routes'] as List).isEmpty ||
          body['routes'][0]['geometry'] == null) {
        throw Exception('No route found');
      }

      final geometry = body['routes'][0]['geometry'];
      final coords = geometry['coordinates'] as List;

      final List<LatLng> pts = coords.map<LatLng>((c) {
        // c = [lon, lat]
        final lon = (c[0] as num).toDouble();
        final lat = (c[1] as num).toDouble();
        return LatLng(lat, lon);
      }).toList();

      if (!mounted) return;
      setState(() {
        _routePoints = pts;
        _errorText = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _errorText = "Route build error: $e";
        // fallback: straight line (optional)
        _routePoints = [start, dest];
      });
    }
  }

  /// ---------- ✅ Realtime location stream ----------
  Future<void> _initMyLocationStream() async {
    final ok = await _ensureLocationPermission();
    if (!ok) return;

    try {
      // first current position
      final pos = await Geolocator.getCurrentPosition(
        desiredAccuracy: LocationAccuracy.high,
      );
      final current = LatLng(pos.latitude, pos.longitude);

      if (!mounted) return;
      setState(() {
        _myLocation = current;
        _center = current;
        _zoom = 16;
        _myTrail = [current]; // trail start from current point
      });
      _mapController.move(current, _zoom);

      // jodi already kono destination select kora thake -> route build
      if (_searchedLocation != null) {
        _buildRoute(); // async, await na দিলেও হবে
      }

      // then stream
      const settings = LocationSettings(
        accuracy: LocationAccuracy.high,
        distanceFilter: 5,
      );

      _positionSub?.cancel();
      _positionSub =
          Geolocator.getPositionStream(locationSettings: settings).listen(
                (pos) async {
              final curr = LatLng(pos.latitude, pos.longitude);
              if (!mounted) return;
              setState(() {
                _myLocation = curr;
                _myTrail.add(curr); // 🔁 live movement trail e add
              });

              // ✅ realtime move holeo route পুনরায় হিসাব
              if (_searchedLocation != null) {
                await _buildRoute();
              }

              if (_followMe) {
                _center = curr;
                _mapController.move(curr, _zoom);
              }
            },
            onError: (e) {
              if (!mounted) return;
              setState(() {
                _errorText = "Realtime location stream error: $e";
              });
            },
          );
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _errorText = "Current location nite problem: $e";
      });
    }
  }

  /// ---------- 🔍 Search API (Nominatim / OpenStreetMap) ----------
  Future<void> _searchLocation() async {
    final rawQuery = _searchController.text.trim();
    if (rawQuery.isEmpty) return;

    setState(() {
      _searching = true;
      _searchResults = [];
      _errorText = null;
    });

    try {
      final uri = Uri.https(
        'nominatim.openstreetmap.org',
        '/search',
        <String, String>{
          'q': rawQuery,
          'format': 'json',
          'limit': '5',
        },
      );

      final resp = await http.get(
        uri,
        headers: {
          'User-Agent': 'flutter_map_realtime_search_demo/1.0',
        },
      );

      if (resp.statusCode != 200) {
        throw Exception('HTTP ${resp.statusCode}');
      }

      final data = json.decode(resp.body);
      if (data is! List || data.isEmpty) {
        setState(() {
          _searchResults = [];
          _searching = false;
          _errorText = "Kono result pai nai.";
        });
        return;
      }

      final List<_PlaceResult> results = [];
      for (final item in data) {
        final lat = double.tryParse(item['lat']?.toString() ?? '');
        final lon = double.tryParse(item['lon']?.toString() ?? '');
        final disp = item['display_name']?.toString() ?? 'Unknown';
        if (lat == null || lon == null) continue;
        results.add(
          _PlaceResult(
            name: disp,
            coord: LatLng(lat, lon),
          ),
        );
      }

      if (results.isEmpty) {
        setState(() {
          _searchResults = [];
          _searching = false;
          _errorText = "Kono result pai nai.";
        });
        return;
      }

      // ✅ auto first result e camera + marker move korbo
      final first = results.first;

      setState(() {
        _searchResults = results; // niche list dekhate chaile thakuk
        _searching = false;
        _searchedLocation = first.coord;
        _center = first.coord;
        _zoom = 16;
      });

      // keyboard hide
      if (mounted) {
        // FocusScope.of(context).unfocus();
      }

      // map camera move
      _mapController.move(first.coord, _zoom);

      // 👉 amar location thakle route build
      if (_myLocation != null && _searchedLocation != null) {
        await _buildRoute();
      } else {
        if (mounted) {
          setState(() {
            _routePoints = [];
          });
        }
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _searching = false;
        _errorText = "Search error: $e";
      });
    }
  }

  /// ---------- Search result select (tap korle oikhane zoom) ----------
  Future<void> _selectSearchResult(_PlaceResult r) async {
    setState(() {
      _searchedLocation = r.coord;
      _center = r.coord;
      _zoom = 16;
      _searchResults = []; // list hide kore dilam
    });

    // keyboard hide
    FocusScope.of(context).unfocus();

    // camera move
    _mapController.move(r.coord, _zoom);

    // route rebuild
    if (_myLocation != null && _searchedLocation != null) {
      await _buildRoute();
    } else {
      setState(() {
        _routePoints = [];
      });
    }
  }

  /// ===================== UI =====================
  @override
  Widget build(BuildContext context) {
    // markers list
    final markers = <Marker>[];

    // ✅ realtime "me" marker
    if (_myLocation != null) {
      markers.add(
        Marker(
          width: 36,
          height: 36,
          point: _myLocation!,
          child: Container(
            decoration: BoxDecoration(
              color: Colors.green.withOpacity(0.9),
              shape: BoxShape.circle,
              border: Border.all(color: Colors.white, width: 2),
            ),
            child: const Icon(
              Icons.person_pin_circle,
              size: 20,
              color: Colors.white,
            ),
          ),
        ),
      );
    }

    // 🔍 searched location marker
    if (_searchedLocation != null) {
      markers.add(
        Marker(
          width: 40,
          height: 40,
          point: _searchedLocation!,
          child: const Icon(
            Icons.location_on,
            color: Colors.red,
            size: 32,
          ),
        ),
      );
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text(
          'Realtime + Search (flutter_map)',
          style: TextStyle(fontWeight: FontWeight.w600),
        ),
        centerTitle: true,
        actions: [
          IconButton(
            tooltip: _followMe ? 'Stop follow' : 'Follow me',
            onPressed: () {
              setState(() {
                _followMe = !_followMe;
              });
            },
            icon: Icon(
              _followMe ? Icons.gps_fixed : Icons.gps_not_fixed,
            ),
          ),
        ],
      ),
      body: Stack(
        children: [
          FlutterMap(
            mapController: _mapController,
            options: MapOptions(
              initialCenter: _center,
              initialZoom: _zoom,
            ),
            children: [
              TileLayer(
                urlTemplate:
                'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                userAgentPackageName: 'com.example.realtime_location',
              ),

              /// 🟢 LIVE TRAIL LAYER (tui jekhane jekhane gesis)
              if (_myTrail.length > 1)
                PolylineLayer(
                  polylines: [
                    Polyline(
                      points: _myTrail,
                      strokeWidth: 3,
                      color: Colors.green.withOpacity(0.7),
                    ),
                  ],
                ),

              /// 🔵 ROAD ROUTE LAYER (OSRM theke asha points)
              if (_routePoints.isNotEmpty)
                PolylineLayer(
                  polylines: [
                    Polyline(
                      points: _routePoints,
                      strokeWidth: 4,
                      color: Colors.blue,
                    ),
                  ],
                ),

              /// Markers last e
              MarkerLayer(markers: markers),
            ],
          ),

          // 🔍 Search bar (top)
          Positioned(
            left: 10,
            right: 10,
            top: 10,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Material(
                  elevation: 4,
                  borderRadius: BorderRadius.circular(12),
                  child: TextField(
                    onChanged: (data){

                      _searchLocation();

                    },
                    controller: _searchController,
                    textInputAction: TextInputAction.search,
                    onSubmitted: (_) => _searchLocation(),
                    decoration: InputDecoration(
                      hintText: 'Search location (e.g. Dhaka, Gulshan)',
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 10,
                      ),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: BorderSide.none,
                      ),
                      suffixIcon: IconButton(
                        icon: _searching
                            ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                          ),
                        )
                            : const Icon(Icons.search),
                        onPressed: _searching ? null : _searchLocation,
                      ),
                    ),
                  ),
                ),

                // search results (small list)
                if (_searchResults.isNotEmpty)
                  Container(
                    margin: const EdgeInsets.only(top: 6),
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(10),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withOpacity(0.15),
                          blurRadius: 8,
                          offset: const Offset(0, 2),
                        ),
                      ],
                    ),
                    constraints: const BoxConstraints(maxHeight: 200),
                    child: ListView.builder(
                      shrinkWrap: true,
                      itemCount: _searchResults.length,
                      itemBuilder: (context, index) {
                        final r = _searchResults[index];
                        return ListTile(
                          dense: true,
                          leading: const Icon(Icons.place, size: 20),
                          title: Text(
                            r.name,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                          onTap: () => _selectSearchResult(r),
                        );
                      },
                    ),
                  ),
              ],
            ),
          ),

          // error text bottom e choto kore
          if (_errorText != null)
            Positioned(
              left: 10,
              right: 10,
              bottom: 16,
              child: Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: Colors.red.withOpacity(0.9),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  _errorText!,
                  style: const TextStyle(color: Colors.white, fontSize: 12),
                  textAlign: TextAlign.center,
                ),
              ),
            ),
        ],
      ),
      floatingActionButton: FloatingActionButton(
        tooltip: 'Go to my location',
        onPressed: _myLocation == null
            ? null
            : () {
          _center = _myLocation!;
          _zoom = 16;
          _mapController.move(_myLocation!, _zoom);
        },
        child: const Icon(Icons.my_location),
      ),
    );
  }
}
