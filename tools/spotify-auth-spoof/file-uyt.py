#!/usr/bin/env python3
"""
Music Scraper Toolkit for Android Spotify-like App
Supports: lucida.to, monochrome.tf, doubledouble.top
"""

import asyncio
import aiohttp
import aiofiles
import json
import os
import re
import hashlib
from typing import Optional, List, Dict, Any, Callable
from dataclasses import dataclass
from pathlib import Path
import logging
from urllib.parse import urlencode, quote

# Configuration du logging
logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)


@dataclass
class Track:
    """Représente une piste musicale"""
    id: str
    title: str
    artist: str
    album: str
    duration: int  # en secondes
    quality: str  # FLAC, MP3 320, etc.
    cover_url: Optional[str] = None
    download_url: Optional[str] = None
    source: str = ""  # lucida, monochrome, doubledouble
    
    def __repr__(self):
        return f"{self.artist} - {self.title} [{self.quality}]"


@dataclass
class SearchResult:
    """Résultat de recherche"""
    tracks: List[Track]
    albums: List[Dict]
    artists: List[Dict]
    total: int


class BaseMusicClient:
    """Classe de base pour tous les clients musicaux"""
    
    def __init__(self, session: Optional[aiohttp.ClientSession] = None):
        self.session = session
        self.headers = {
            'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36'
        }
    
    async def __aenter__(self):
        if self.session is None:
            self.session = aiohttp.ClientSession(headers=self.headers)
        return self
    
    async def __aexit__(self, exc_type, exc_val, exc_tb):
        if self.session:
            await self.session.close()
    
    async def search(self, query: str, limit: int = 20) -> SearchResult:
        raise NotImplementedError
    
    async def get_download_url(self, track_id: str) -> Optional[str]:
        raise NotImplementedError
    
    async def download_track(self, track: Track, output_dir: str = "./downloads", 
                          progress_callback: Optional[Callable] = None) -> str:
        """Télécharge une piste avec barre de progression"""
        if not track.download_url:
            raise ValueError("URL de téléchargement non disponible")
        
        output_path = Path(output_dir)
        output_path.mkdir(parents=True, exist_ok=True)
        
        # Créer un nom de fichier sécurisé
        safe_title = re.sub(r'[^\w\s-]', '', track.title).strip()
        safe_artist = re.sub(r'[^\w\s-]', '', track.artist).strip()
        filename = f"{safe_artist} - {safe_title}.flac"
        filepath = output_path / filename
        
        async with self.session.get(track.download_url) as response:
            if response.status != 200:
                raise Exception(f"Erreur HTTP {response.status}")
            
            total_size = int(response.headers.get('content-length', 0))
            downloaded = 0
            
            async with aiofiles.open(filepath, 'wb') as f:
                async for chunk in response.content.iter_chunked(8192):
                    await f.write(chunk)
                    downloaded += len(chunk)
                    
                    if progress_callback and total_size > 0:
                        progress = (downloaded / total_size) * 100
                        progress_callback(track.id, progress, downloaded, total_size)
        
        logger.info(f"Téléchargé: {filename}")
        return str(filepath)


class LucidaClient(BaseMusicClient):
    """
    Client pour lucida.to
    API non officielle - basée sur l'analyse du site
    """
    
    BASE_URL = "https://lucida.to"
    API_URL = "https://api.lucida.to"  # Endpoint hypothétique
    
    SERVICES = {
        'qobuz': 'Qobuz',
        'tidal': 'Tidal', 
        'deezer': 'Deezer',
        'amazon': 'Amazon Music',
        'yandex': 'Yandex Music',
        'soundcloud': 'SoundCloud'
    }
    
    async def search(self, query: str, service: str = 'qobuz', 
                   limit: int = 20) -> SearchResult:
        """
        Recherche sur Lucida
        service: qobuz, tidal, deezer, amazon, yandex, soundcloud
        """
        # Endpoint de recherche (basé sur l'analyse du site)
        search_url = f"{self.BASE_URL}/api/search"
        
        params = {
            'q': query,
            'service': service,
            'limit': limit
        }
        
        async with self.session.get(search_url, params=params) as response:
            if response.status != 200:
                # Fallback: simuler une recherche via scraping
                return await self._search_fallback(query, service, limit)
            
            data = await response.json()
            return self._parse_search_results(data)
    
    async def _search_fallback(self, query: str, service: str, 
                               limit: int) -> SearchResult:
        """Méthode alternative si l'API n'est pas disponible"""
        # Utilise l'interface web directement
        url = f"{self.BASE_URL}/"
        
        # Note: Dans la pratique, il faudrait parser le HTML ou utiliser 
        # l'API interne du site. Ceci est une structure exemple.
        logger.warning("Utilisation du mode fallback pour Lucida")
        
        return SearchResult(tracks=[], albums=[], artists=[], total=0)
    
    def _parse_search_results(self, data: Dict) -> SearchResult:
        """Parse les résultats de recherche"""
        tracks = []
        for item in data.get('tracks', []):
            tracks.append(Track(
                id=item.get('id'),
                title=item.get('title'),
                artist=item.get('artist', {}).get('name', 'Unknown'),
                album=item.get('album', {}).get('title', 'Unknown'),
                duration=item.get('duration', 0),
                quality=item.get('quality', 'FLAC'),
                cover_url=item.get('album', {}).get('cover'),
                source='lucida'
            ))
        
        return SearchResult(
            tracks=tracks,
            albums=data.get('albums', []),
            artists=data.get('artists', []),
            total=len(tracks)
        )
    
    async def get_download_url(self, track_id: str, service: str = 'qobuz') -> Optional[str]:
        """Récupère l'URL de téléchargement"""
        # Endpoint de téléchargement
        download_endpoint = f"{self.BASE_URL}/api/download"
        
        payload = {
            'id': track_id,
            'service': service,
            'quality': 'lossless'
        }
        
        async with self.session.post(download_endpoint, json=payload) as response:
            if response.status == 200:
                data = await response.json()
                return data.get('download_url')
        return None
    
    async def download_by_url(self, url: str, output_dir: str = "./downloads") -> str:
        """
        Télécharge directement depuis une URL lucida.to
        C'est la méthode la plus fiable car Lucida est conçu pour ça
        """
        # Extraire l'ID de l'URL si c'est une URL complète
        # Format: https://lucida.to/download/...
        
        output_path = Path(output_dir)
        output_path.mkdir(parents=True, exist_ok=True)
        
        async with self.session.get(url, allow_redirects=True) as response:
            if response.status != 200:
                raise Exception(f"Erreur lors du téléchargement: {response.status}")
            
            # Détecter le nom du fichier
            content_disposition = response.headers.get('content-disposition', '')
            filename = None
            
            if 'filename=' in content_disposition:
                filename = content_disposition.split('filename=')[1].strip('"\'')
            else:
                # Générer un nom basé sur l'URL
                url_hash = hashlib.md5(url.encode()).hexdigest()[:8]
                filename = f"lucida_download_{url_hash}.flac"
            
            filepath = output_path / filename
            
            async with aiofiles.open(filepath, 'wb') as f:
                async for chunk in response.content.iter_chunked(8192):
                    await f.write(chunk)
        
        return str(filepath)


class MonochromeClient(BaseMusicClient):
    """
    Client pour monochrome.tf
    Utilise l'API Hi-Fi exposée
    """
    
    # Instances API disponibles (basé sur INSTANCES.md)
    API_INSTANCES = [
        "https://api.monochrome.tf",
        "https://monochrome-api.samidy.com",
        "https://hifi.geeked.wtf",
        "https://wolf.qqdl.site",
        "https://maus.qqdl.site",
        "https://vogel.qqdl.site",
        "https://katze.qqdl.site",
        "https://hund.qqdl.site",
    ]
    
    def __init__(self, api_instance: Optional[str] = None, 
                 session: Optional[aiohttp.ClientSession] = None):
        super().__init__(session)
        self.base_url = api_instance or self.API_INSTANCES[0]
        self.headers.update({
            'Accept': 'application/json',
            'Content-Type': 'application/json'
        })
    
    async def search(self, query: str, limit: int = 20) -> SearchResult:
        """Recherche sur Monochrome"""
        search_url = f"{self.base_url}/search"
        
        params = {
            'q': query,
            'limit': limit,
            'type': 'track'
        }
        
        async with self.session.get(search_url, params=params) as response:
            if response.status != 200:
                # Essayer une autre instance
                return await self._try_other_instances(query, limit)
            
            data = await response.json()
            return self._parse_search_results(data)
    
    async def _try_other_instances(self, query: str, limit: int) -> SearchResult:
        """Essaie d'autres instances si la principale échoue"""
        for instance in self.API_INSTANCES[1:]:
            try:
                self.base_url = instance
                return await self.search(query, limit)
            except Exception as e:
                logger.warning(f"Instance {instance} failed: {e}")
                continue
        
        raise Exception("Toutes les instances sont indisponibles")
    
    def _parse_search_results(self, data: Dict) -> SearchResult:
        """Parse les résultats Monochrome"""
        tracks = []
        for item in data.get('data', []):
            tracks.append(Track(
                id=str(item.get('id')),
                title=item.get('title'),
                artist=', '.join(a['name'] for a in item.get('artists', [])),
                album=item.get('album', {}).get('title', 'Unknown'),
                duration=item.get('duration', 0) // 1000,  # ms to s
                quality=self._get_quality_label(item),
                cover_url=item.get('album', {}).get('cover'),
                source='monochrome'
            ))
        
        return SearchResult(
            tracks=tracks,
            albums=data.get('albums', []),
            artists=data.get('artists', []),
            total=len(tracks)
        )
    
    def _get_quality_label(self, item: Dict) -> str:
        """Détermine la qualité audio"""
        quality = item.get('quality', {})
        if quality.get('hi_res'):
            return "HI-RES FLAC"
        elif quality.get('lossless'):
            return "FLAC"
        else:
            return f"MP3 {quality.get('bitrate', 320)}kbps"
    
    async def get_download_url(self, track_id: str, quality: str = "lossless") -> Optional[str]:
        """Récupère l'URL de streaming/téléchargement"""
        stream_url = f"{self.base_url}/track/{track_id}/stream"
        
        params = {
            'quality': quality,
            'format': 'flac'
        }
        
        async with self.session.get(stream_url, params=params) as response:
            if response.status == 200:
                data = await response.json()
                return data.get('url')
        return None
    
    async def get_track_info(self, track_id: str) -> Dict:
        """Récupère les informations détaillées d'une piste"""
        info_url = f"{self.base_url}/track/{track_id}"
        
        async with self.session.get(info_url) as response:
            if response.status == 200:
                return await response.json()
            return {}


class DoubleDoubleClient(BaseMusicClient):
    """
    Client pour doubledouble.top
    Télécharge depuis Spotify, Apple Music, etc.
    """
    
    REGIONS = {
        'us': 'https://us.doubledouble.top',
        'eu': 'https://eu.doubledouble.top'
    }
    
    def __init__(self, region: str = 'us', 
                 session: Optional[aiohttp.ClientSession] = None):
        super().__init__(session)
        self.base_url = self.REGIONS.get(region, self.REGIONS['us'])
    
    async def search(self, query: str, source: str = 'spotify', 
                   limit: int = 20) -> SearchResult:
        """
        Recherche sur DoubleDouble
        source: spotify, apple_music, tidal, deezer, etc.
        """
        search_url = f"{self.base_url}/api/search"
        
        params = {
            'q': query,
            'source': source,
            'limit': limit
        }
        
        async with self.session.get(search_url, params=params) as response:
            if response.status != 200:
                # DoubleDouble fonctionne souvent avec des URLs directes
                return await self._search_via_proxy(query, source, limit)
            
            data = await response.json()
            return self._parse_results(data)
    
    async def _search_via_proxy(self, query: str, source: str, limit: int) -> SearchResult:
        """Recherche alternative via parsing"""
        # DoubleDouble fonctionne mieux avec des URLs de services
        # comme Spotify ou Apple Music directement
        logger.info(f"Recherche {source} pour: {query}")
        
        # Structure de résultat vide pour l'instant
        return SearchResult(tracks=[], albums=[], artists=[], total=0)
    
    def _parse_results(self, data: Dict) -> SearchResult:
        """Parse les résultats DoubleDouble"""
        tracks = []
        for item in data.get('tracks', []):
            tracks.append(Track(
                id=item.get('id'),
                title=item.get('name'),
                artist=', '.join(a['name'] for a in item.get('artists', [])),
                album=item.get('album', {}).get('name', 'Unknown'),
                duration=item.get('duration_ms', 0) // 1000,
                quality=item.get('quality', 'AAC 256'),
                cover_url=item.get('album', {}).get('images', [{}])[0].get('url'),
                source='doubledouble'
            ))
        
        return SearchResult(tracks=tracks, albums=[], artists=[], total=len(tracks))
    
    async def download_from_url(self, service_url: str, output_dir: str = "./downloads") -> str:
        """
        Télécharge depuis une URL de service (Spotify, Apple Music, etc.)
        C'est la méthode principale pour DoubleDouble
        """
        # DoubleDouble fonctionne en collant l'URL d'un service
        download_endpoint = f"{self.base_url}/download"
        
        payload = {
            'url': service_url,
            'quality': 'lossless',
            'format': 'auto'
        }
        
        async with self.session.post(download_endpoint, json=payload) as response:
            if response.status != 200:
                raise Exception(f"Erreur: {response.status}")
            
            data = await response.json()
            download_url = data.get('download_url')
            
            if not download_url:
                raise Exception("URL de téléchargement non trouvée")
            
            # Télécharger le fichier
            return await self._download_file(download_url, output_dir, data)
    
    async def _download_file(self, url: str, output_dir: str, metadata: Dict) -> str:
        """Télécharge le fichier avec métadonnées"""
        output_path = Path(output_dir)
        output_path.mkdir(parents=True, exist_ok=True)
        
        # Construire le nom de fichier
        artist = metadata.get('artist', 'Unknown')
        title = metadata.get('title', 'Unknown')
        filename = f"{artist} - {title}.flac"
        filename = re.sub(r'[<>:"/\\|?*]', '', filename)
        
        filepath = output_path / filename
        
        async with self.session.get(url) as response:
            async with aiofiles.open(filepath, 'wb') as f:
                async for chunk in response.content.iter_chunked(8192):
                    await f.write(chunk)
        
        return str(filepath)


class MusicAggregator:
    """
    Agrège les résultats de plusieurs sources
    Pour une app type Spotify, c'est la classe principale à utiliser
    """
    
    def __init__(self):
        self.clients = {
            'lucida': None,
            'monochrome': None,
            'doubledouble': None
        }
        self.session = None
    
    async def __aenter__(self):
        self.session = aiohttp.ClientSession()
        self.clients['lucida'] = LucidaClient(self.session)
        self.clients['monochrome'] = MonochromeClient(session=self.session)
        self.clients['doubledouble'] = DoubleDoubleClient(session=self.session)
        return self
    
    async def __aexit__(self, exc_type, exc_val, exc_tb):
        if self.session:
            await self.session.close()
    
    async def search_all(self, query: str, sources: Optional[List[str]] = None,
                        limit_per_source: int = 10) -> Dict[str, SearchResult]:
        """
        Recherche sur toutes les sources ou celles spécifiées
        """
        sources = sources or list(self.clients.keys())
        results = {}
        
        tasks = []
        for source in sources:
            if source in self.clients:
                client = self.clients[source]
                task = asyncio.create_task(
                    self._safe_search(client, query, limit_per_source),
                    name=source
                )
                tasks.append((source, task))
        
        for source, task in tasks:
            try:
                result = await task
                results[source] = result
            except Exception as e:
                logger.error(f"Erreur {source}: {e}")
                results[source] = SearchResult([], [], [], 0)
        
        return results
    
    async def _safe_search(self, client, query: str, limit: int) -> SearchResult:
        """Recherche avec gestion d'erreurs"""
        try:
            return await client.search(query, limit=limit)
        except Exception as e:
            logger.warning(f"Search failed: {e}")
            return SearchResult([], [], [], 0)
    
    async def download_best_quality(self, track: Track, output_dir: str = "./downloads",
                                   progress_callback: Optional[Callable] = None) -> str:
        """
        Télécharge la meilleure qualité disponible
        """
        client = self.clients.get(track.source)
        if not client:
            raise ValueError(f"Client non trouvé pour {track.source}")
        
        # Récupérer l'URL de téléchargement si pas déjà présente
        if not track.download_url:
            track.download_url = await client.get_download_url(track.id)
        
        return await client.download_track(track, output_dir, progress_callback)
    
    def merge_results(self, results: Dict[str, SearchResult]) -> List[Track]:
        """
        Fusionne et déduplique les résultats de plusieurs sources
        """
        all_tracks = []
        seen_ids = set()
        
        for source, result in results.items():
            for track in result.tracks:
                # Créer une clé unique pour déduplication
                key = f"{track.artist.lower()}|{track.title.lower()}"
                if key not in seen_ids:
                    seen_ids.add(key)
                    all_tracks.append(track)
        
        # Trier par qualité (HI-RES > FLAC > MP3)
        quality_order = {'HI-RES FLAC': 3, 'FLAC': 2, 'AAC 320': 1, 'MP3 320': 1}
        all_tracks.sort(
            key=lambda t: quality_order.get(t.quality, 0),
            reverse=True
        )
        
        return all_tracks


# ============== INTERFACE POUR ANDROID ==============

class AndroidMusicProvider:
    """
    Interface haut niveau pour intégration dans une app Android
    Utilisable avec Chaquopy (Python dans Android)
    """
    
    def __init__(self):
        self.aggregator = None
        self.download_queue = []
    
    async def initialize(self):
        """Initialise le provider"""
        self.aggregator = MusicAggregator()
        await self.aggregator.__aenter__()
    
    async def close(self):
        """Ferme le provider"""
        if self.aggregator:
            await self.aggregator.__aexit__(None, None, None)
    
    async def search_tracks(self, query: str) -> List[Dict]:
        """
        Recherche de pistes - retourne des dicts sérialisables pour Android
        """
        results = await self.aggregator.search_all(query, limit_per_source=5)
        merged = self.aggregator.merge_results(results)
        
        # Convertir en dicts pour JSON
        return [
            {
                'id': t.id,
                'title': t.title,
                'artist': t.artist,
                'album': t.album,
                'duration': t.duration,
                'quality': t.quality,
                'cover_url': t.cover_url,
                'source': t.source
            }
            for t in merged[:20]  # Limiter les résultats
        ]
    
    async def download_track(self, track_dict: Dict, output_path: str,
                            progress_callback: Optional[Callable] = None) -> str:
        """
        Télécharge une piste à partir d'un dict (reçu de Android)
        """
        track = Track(
            id=track_dict['id'],
            title=track_dict['title'],
            artist=track_dict['artist'],
            album=track_dict['album'],
            duration=track_dict['duration'],
            quality=track_dict['quality'],
            cover_url=track_dict.get('cover_url'),
            source=track_dict['source']
        )
        
        return await self.aggregator.download_best_quality(
            track, output_path, progress_callback
        )


# ============== CLI ==============

async def main():
    """Fonction principale pour tests CLI"""
    import argparse
    
    parser = argparse.ArgumentParser(description='Music Scraper Toolkit')
    parser.add_argument('command', choices=['search', 'download'], help='Commande')
    parser.add_argument('query', help='Requête de recherche ou URL')
    parser.add_argument('--source', '-s', choices=['lucida', 'monochrome', 'doubledouble', 'all'],
                       default='all', help='Source musicale')
    parser.add_argument('--output', '-o', default='./downloads', help='Dossier de sortie')
    parser.add_argument('--limit', '-l', type=int, default=10, help='Nombre de résultats')
    
    args = parser.parse_args()
    
    async with MusicAggregator() as aggregator:
        if args.command == 'search':
            print(f"🔍 Recherche: {args.query}")
            
            sources = [args.source] if args.source != 'all' else None
            results = await aggregator.search_all(args.query, sources, args.limit)
            
            # Afficher les résultats
            for source, result in results.items():
                print(f"\n📀 {source.upper()}:")
                for track in result.tracks[:5]:
                    print(f"  • {track.artist} - {track.title} [{track.quality}]")
        
        elif args.command == 'download':
            print(f"⬇️  Téléchargement depuis: {args.query}")
            # Logique de téléchargement direct


if __name__ == '__main__':
    asyncio.run(main())